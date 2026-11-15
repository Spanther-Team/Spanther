import Foundation

// SpriteKit fragment shaders, as GLSL source for SKShader (which compiles them to Metal). SpriteKit gives every
// shader u_texture, v_tex_coord (0...1 over the sprite's texture, v = 1 at the top), u_time (seconds) and
// v_color_mix (its alpha is the node's alpha). Textures are premultiplied alpha, and so is everything written to
// gl_FragColor here.
//
// The sources declare no uniforms: SKShader adds the declarations for the SKUniforms the app attaches, under the
// names listed in `uniforms`. Each sprite needs a texture of its own, not one cut from an atlas, because the
// shaders take v_tex_coord to run over 0...1.

public enum FeelShaders {
    /// For a crack overlay sprite whose own texture is the crack map: red = distance along the crack 0...1
    /// (premultiplied by alpha, so the shader divides by alpha), alpha = crack mask. Draws ink (u_ink, vec4
    /// premultiplied colour) where the stored distance <= u_progress, with a soft front about 0.04 wide;
    /// transparent elsewhere. Nothing shows at u_progress 0, everything at 1.
    /// Uniforms: u_progress (float), u_ink (vec4).
    public static let crackReveal: String = """
    void main() {
        vec4 crack = texture2D(u_texture, v_tex_coord);
        float along = crack.r / max(crack.a, 0.0001);
        float front = u_progress * 1.04;
        float shown = 1.0 - smoothstep(front - 0.04, front, along);
        gl_FragColor = u_ink * (crack.a * shown * v_color_mix.a);
    }
    """

    /// Wind: shifts the texture lookup sideways by u_amplitude (texture units) ×
    /// sin(u_time × u_speed + v_tex_coord.y × 5.0 + u_phase), weighted so the anchored edge stays still:
    /// u_anchor 1 = hangs from the top edge (v = 1 still), 0 = grows from the bottom edge (v = 0 still). Lookups
    /// outside 0...1 give transparent. Uniforms: u_amplitude, u_speed, u_phase, u_anchor (floats).
    public static let windSway: String = """
    void main() {
        float weight = mix(v_tex_coord.y, 1.0 - v_tex_coord.y, u_anchor);
        float wave = sin(u_time * u_speed + v_tex_coord.y * 5.0 + u_phase);
        vec2 uv = vec2(v_tex_coord.x + u_amplitude * wave * weight, v_tex_coord.y);
        float within = step(0.0, uv.x) * step(uv.x, 1.0);
        gl_FragColor = texture2D(u_texture, uv) * (within * v_color_mix.a);
    }
    """

    /// Dissolve: hash noise per cell (from v_tex_coord × u_cells), drops the pixels whose noise < u_dissolve
    /// (written as transparent, which is the same as a discard under premultiplied alpha), and paints u_edge (vec4
    /// premultiplied) on a thin band just above the threshold. u_dissolve 0 shows the whole texture, 1 nothing.
    /// Uniforms: u_dissolve, u_cells (floats), u_edge (vec4).
    public static let dissolve: String = """
    void main() {
        vec4 pixel = texture2D(u_texture, v_tex_coord);
        vec2 cell = floor(v_tex_coord * u_cells);
        float grain = fract(sin(dot(cell, vec2(12.9898, 78.233))) * 43758.5453);
        float kept = step(u_dissolve, grain);
        float band = kept * step(grain, u_dissolve + 0.06) * step(0.0001, u_dissolve);
        vec4 edged = mix(pixel, u_edge * pixel.a, band);
        gl_FragColor = edged * (kept * v_color_mix.a);
    }
    """

    /// Uniform names per shader, for the app's wiring and the tests.
    public static let uniforms: [String: [String]] = [
        "crackReveal": ["u_progress", "u_ink"],
        "windSway": ["u_amplitude", "u_speed", "u_phase", "u_anchor"],
        "dissolve": ["u_dissolve", "u_cells", "u_edge"],
    ]
}
