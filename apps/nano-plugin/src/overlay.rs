//! The host overlay drawn over the whole module strip (ADR 0004, Phase F3): the right-click context
//! menu and the empty-strip hint. Unlike a Module — which is clipped to one column's viewport — the
//! overlay spans the surface (the menu can overlap columns), so it draws in its OWN `LoadOp::Load`
//! pass with no per-column viewport/scissor: quad geometry in full-surface clip space, text projected
//! to full-surface px. The pass is skipped entirely when there's nothing to show, so the common case
//! (no menu, non-empty strip) costs nothing.

use std::borrow::Cow;

use bytemuck::{Pod, Zeroable};
use wgpu_text::glyph_brush::ab_glyph::FontRef;
use wgpu_text::glyph_brush::{HorizontalAlign, Layout, Section, Text, VerticalAlign};
use wgpu_text::{BrushBuilder, TextBrush};

use crate::input::MenuOverlay;
use crate::menu::menu_rect;
use crate::module::FONT;

type Brush = TextBrush<FontRef<'static>>;

const PANEL_RGB: [f32; 3] = [0.10, 0.11, 0.14]; // menu panel — a touch above the near-black bg
const HOVER_RGB: [f32; 3] = [0.20, 0.40, 0.58]; // the hovered row
const TEXT_COLOR: [f32; 4] = [0.86, 0.90, 0.98, 1.0]; // row labels
const HINT_COLOR: [f32; 4] = [0.45, 0.50, 0.60, 1.0]; // the empty-strip hint

const TEXT_PX: f32 = 13.0; // row-label / hint size, LOGICAL px (× scale at draw)
const ROW_PAD_X: f32 = 10.0; // label inset from the panel's left edge, LOGICAL px
const SEAM_RGB: [f32; 3] = [0.30, 0.34, 0.42]; // a draggable flex|flex divider (F4)
const SEAM_W: f32 = 1.5; // divider thickness, LOGICAL px (× scale at draw)
/// Vertex-buffer capacity in quads: the menu panel + hover row, plus a generous run of seam
/// hairlines (one per draggable boundary). Seams beyond this are skipped rather than overflow the
/// buffer — far past any sane column count. Rows are text (the brush), not quads, so this stays small.
const MAX_QUADS: usize = 32;

#[repr(C)]
#[derive(Copy, Clone, Pod, Zeroable)]
struct Vertex {
    pos: [f32; 2],
    color: [f32; 3],
}

/// Push a surface-px rectangle (`y0` top, `y1` bottom) as two clip-space triangles. Mirrors the
/// Loudness module's `push_quad`, but converts px → clip here (the overlay works in surface px).
fn push_quad(verts: &mut Vec<Vertex>, sw: f32, sh: f32, x0: f32, x1: f32, y0: f32, y1: f32, color: [f32; 3]) {
    let cx = |px: f32| px / sw * 2.0 - 1.0;
    let cy = |px: f32| 1.0 - px / sh * 2.0; // screen top-down → clip y-up
    let (l, r, t, b) = (cx(x0), cx(x1), cy(y0), cy(y1));
    for pos in [[l, t], [r, t], [r, b], [l, t], [r, b], [l, b]] {
        verts.push(Vertex { pos, color });
    }
}

pub struct Overlay {
    brush: Brush,
    /// Current `resize_view` size, so we only re-project the brush when the surface changes.
    brush_size: (u32, u32),
    pipeline: wgpu::RenderPipeline,
    vbuf: wgpu::Buffer,
    verts: Vec<Vertex>,
}

impl Overlay {
    pub fn new(device: &wgpu::Device, format: wgpu::TextureFormat) -> Self {
        let brush = BrushBuilder::using_font_bytes(FONT)
            .expect("embedded JetBrains Mono is a valid OFL TTF")
            .build(device, 256, 256, format);

        let shader = device.create_shader_module(wgpu::ShaderModuleDescriptor {
            label: Some("overlay-shader"),
            source: wgpu::ShaderSource::Wgsl(Cow::Borrowed(QUAD_WGSL)),
        });
        let pipeline_layout = device.create_pipeline_layout(&wgpu::PipelineLayoutDescriptor {
            label: Some("overlay-pl"),
            bind_group_layouts: &[],
            immediate_size: 0,
        });
        let vertex_layout = wgpu::VertexBufferLayout {
            array_stride: std::mem::size_of::<Vertex>() as u64,
            step_mode: wgpu::VertexStepMode::Vertex,
            attributes: &[
                wgpu::VertexAttribute {
                    shader_location: 0,
                    format: wgpu::VertexFormat::Float32x2,
                    offset: 0,
                },
                wgpu::VertexAttribute {
                    shader_location: 1,
                    format: wgpu::VertexFormat::Float32x3,
                    offset: std::mem::size_of::<[f32; 2]>() as u64,
                },
            ],
        };
        let pipeline = device.create_render_pipeline(&wgpu::RenderPipelineDescriptor {
            label: Some("overlay-pipeline"),
            layout: Some(&pipeline_layout),
            vertex: wgpu::VertexState {
                module: &shader,
                entry_point: Some("vs_main"),
                buffers: &[vertex_layout],
                compilation_options: Default::default(),
            },
            fragment: Some(wgpu::FragmentState {
                module: &shader,
                entry_point: Some("fs_main"),
                compilation_options: Default::default(),
                targets: &[Some(wgpu::ColorTargetState {
                    format,
                    blend: None,
                    write_mask: wgpu::ColorWrites::ALL,
                })],
            }),
            primitive: wgpu::PrimitiveState {
                topology: wgpu::PrimitiveTopology::TriangleList,
                ..Default::default()
            },
            depth_stencil: None,
            multisample: wgpu::MultisampleState::default(),
            multiview_mask: None,
            cache: None,
        });

        let vbuf = device.create_buffer(&wgpu::BufferDescriptor {
            label: Some("overlay-vbuf"),
            size: (MAX_QUADS * 6 * std::mem::size_of::<Vertex>()) as u64,
            usage: wgpu::BufferUsages::VERTEX | wgpu::BufferUsages::COPY_DST,
            mapped_at_creation: false,
        });

        Self { brush, brush_size: (0, 0), pipeline, vbuf, verts: Vec::with_capacity(MAX_QUADS * 6) }
    }

    /// Draw the overlay into `view` in its own load pass — but only if there's something to show.
    /// `menu` is the open context menu (`None` when closed); `strip_empty` draws the right-click hint;
    /// `seams` are the physical-px x of draggable flex|flex boundaries, each drawn as a hairline so the
    /// resize affordance (F4) is visible.
    #[allow(clippy::too_many_arguments)]
    pub fn render(
        &mut self,
        device: &wgpu::Device,
        queue: &wgpu::Queue,
        encoder: &mut wgpu::CommandEncoder,
        view: &wgpu::TextureView,
        surface_w: f32,
        surface_h: f32,
        scale: f32,
        menu: Option<MenuOverlay>,
        strip_empty: bool,
        seams: &[f32],
    ) {
        if menu.is_none() && !strip_empty && seams.is_empty() {
            return;
        }

        // Project the brush onto the full surface (px coordinates) when the surface changes.
        let size = (surface_w.max(1.0) as u32, surface_h.max(1.0) as u32);
        if size != self.brush_size {
            self.brush.resize_view(size.0 as f32, size.1 as f32, queue);
            self.brush_size = size;
        }

        self.verts.clear();
        let mut sections: Vec<Section> = Vec::new();
        let font = TEXT_PX * scale;

        // Draggable flex|flex seams: a centered hairline at each (capped to the vertex budget, which
        // leaves room for the menu's quads).
        let half = SEAM_W * scale * 0.5;
        for &x in seams.iter().take(MAX_QUADS - 2) {
            push_quad(&mut self.verts, surface_w, surface_h, x - half, x + half, 0.0, surface_h, SEAM_RGB);
        }

        if strip_empty {
            sections.push(
                Section::default()
                    .with_screen_position((surface_w * 0.5, surface_h * 0.5))
                    .with_layout(
                        Layout::default_single_line()
                            .h_align(HorizontalAlign::Center)
                            .v_align(VerticalAlign::Center),
                    )
                    .add_text(
                        Text::new("right-click to add a module")
                            .with_scale(font)
                            .with_color(HINT_COLOR),
                    ),
            );
        }

        if let Some(menu) = menu {
            let n = menu.items.len();
            let rect = menu_rect(menu.anchor, n, surface_w, surface_h, scale);
            let row_h = if n > 0 { rect.h / n as f32 } else { rect.h };

            push_quad(&mut self.verts, surface_w, surface_h, rect.x, rect.x + rect.w, rect.y, rect.y + rect.h, PANEL_RGB);
            if let Some(h) = menu.hovered {
                let ry = rect.y + h as f32 * row_h;
                push_quad(&mut self.verts, surface_w, surface_h, rect.x, rect.x + rect.w, ry, ry + row_h, HOVER_RGB);
            }
            for (i, item) in menu.items.iter().enumerate() {
                let ty = rect.y + (i as f32 + 0.5) * row_h; // vertically centered in its row
                sections.push(
                    Section::default()
                        .with_screen_position((rect.x + ROW_PAD_X * scale, ty))
                        .with_layout(Layout::default_single_line().v_align(VerticalAlign::Center))
                        .add_text(Text::new(item.label.as_str()).with_scale(font).with_color(TEXT_COLOR)),
                );
            }
        }

        queue.write_buffer(&self.vbuf, 0, bytemuck::cast_slice(&self.verts));
        let _ = self.brush.queue(device, queue, &sections);

        // Second pass: LOAD the strip the modules just drew, then paint the overlay over it. Full
        // surface — no viewport/scissor, so the menu spans columns.
        let mut rpass = encoder.begin_render_pass(&wgpu::RenderPassDescriptor {
            label: Some("nanometers-overlay"),
            color_attachments: &[Some(wgpu::RenderPassColorAttachment {
                view,
                resolve_target: None,
                ops: wgpu::Operations { load: wgpu::LoadOp::Load, store: wgpu::StoreOp::Store },
                depth_slice: None,
            })],
            depth_stencil_attachment: None,
            timestamp_writes: None,
            occlusion_query_set: None,
            multiview_mask: None,
        });
        if !self.verts.is_empty() {
            rpass.set_pipeline(&self.pipeline);
            rpass.set_vertex_buffer(0, self.vbuf.slice(..));
            rpass.draw(0..self.verts.len() as u32, 0..1);
        }
        self.brush.draw(&mut rpass);
    }
}

const QUAD_WGSL: &str = r#"
struct VsOut {
    @builtin(position) clip: vec4<f32>,
    @location(0) color: vec3<f32>,
};

@vertex
fn vs_main(@location(0) pos: vec2<f32>, @location(1) color: vec3<f32>) -> VsOut {
    var o: VsOut;
    o.clip = vec4<f32>(pos, 0.0, 1.0);
    o.color = color;
    return o;
}

@fragment
fn fs_main(in: VsOut) -> @location(0) vec4<f32> {
    return vec4<f32>(in.color, 1.0);
}
"#;
