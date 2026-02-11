const std = @import("std");

const c = @cImport({
    @cInclude("glad/gl.h");
});

const SCREEN_W = 160;
const SCREEN_H = 144;

pub const Renderer = struct {
    vao: c.GLuint,
    vbo: c.GLuint,
    ebo: c.GLuint,
    texture: c.GLuint,
    crt_program: c.GLuint,
    passthrough_program: c.GLuint,
    crt_enabled: bool,

    u_resolution: c.GLint,
    u_texture_size: c.GLint,

    pub fn init(width: u32, height: u32) Renderer {
        const vertices = [_]f32{
            -1.0, -1.0, 0.0, 1.0,
            1.0,  -1.0, 1.0, 1.0,
            1.0,  1.0,  1.0, 0.0,
            -1.0, 1.0,  0.0, 0.0,
        };
        const indices = [_]u32{ 0, 1, 2, 2, 3, 0 };

        var vao: c.GLuint = 0;
        var vbo: c.GLuint = 0;
        var ebo: c.GLuint = 0;
        c.glGenVertexArrays(1, &vao);
        c.glGenBuffers(1, &vbo);
        c.glGenBuffers(1, &ebo);

        c.glBindVertexArray(vao);

        c.glBindBuffer(c.GL_ARRAY_BUFFER, vbo);
        c.glBufferData(c.GL_ARRAY_BUFFER, @sizeOf(@TypeOf(vertices)), &vertices, c.GL_STATIC_DRAW);

        c.glBindBuffer(c.GL_ELEMENT_ARRAY_BUFFER, ebo);
        c.glBufferData(c.GL_ELEMENT_ARRAY_BUFFER, @sizeOf(@TypeOf(indices)), &indices, c.GL_STATIC_DRAW);

        c.glVertexAttribPointer(0, 2, c.GL_FLOAT, c.GL_FALSE, 4 * @sizeOf(f32), @ptrFromInt(0));
        c.glEnableVertexAttribArray(0);

        c.glVertexAttribPointer(1, 2, c.GL_FLOAT, c.GL_FALSE, 4 * @sizeOf(f32), @ptrFromInt(2 * @sizeOf(f32)));
        c.glEnableVertexAttribArray(1);

        c.glBindVertexArray(0);

        var texture: c.GLuint = 0;
        c.glGenTextures(1, &texture);
        c.glBindTexture(c.GL_TEXTURE_2D, texture);
        c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MIN_FILTER, c.GL_NEAREST);
        c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MAG_FILTER, c.GL_NEAREST);
        c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_S, c.GL_CLAMP_TO_EDGE);
        c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_T, c.GL_CLAMP_TO_EDGE);
        c.glTexImage2D(c.GL_TEXTURE_2D, 0, c.GL_RGBA8, SCREEN_W, SCREEN_H, 0, c.GL_BGRA, c.GL_UNSIGNED_INT_8_8_8_8_REV, null);
        c.glBindTexture(c.GL_TEXTURE_2D, 0);

        const vert_src = @embedFile("shaders/crt.vert");
        const crt_frag_src = @embedFile("shaders/crt.frag");
        const pass_frag_src = @embedFile("shaders/passthrough.frag");

        const crt_program = createProgram(vert_src, crt_frag_src);
        const passthrough_program = createProgram(vert_src, pass_frag_src);

        const u_resolution = c.glGetUniformLocation(crt_program, "u_resolution");
        const u_texture_size = c.glGetUniformLocation(crt_program, "u_texture_size");

        c.glUseProgram(crt_program);
        c.glUniform2f(u_resolution, @floatFromInt(width), @floatFromInt(height));
        c.glUniform2f(u_texture_size, SCREEN_W, SCREEN_H);
        c.glUseProgram(0);

        return Renderer{
            .vao = vao,
            .vbo = vbo,
            .ebo = ebo,
            .texture = texture,
            .crt_program = crt_program,
            .passthrough_program = passthrough_program,
            .crt_enabled = true,
            .u_resolution = u_resolution,
            .u_texture_size = u_texture_size,
        };
    }

    pub fn deinit(self: *Renderer) void {
        c.glDeleteProgram(self.crt_program);
        c.glDeleteProgram(self.passthrough_program);
        c.glDeleteTextures(1, &self.texture);
        c.glDeleteBuffers(1, &self.ebo);
        c.glDeleteBuffers(1, &self.vbo);
        c.glDeleteVertexArrays(1, &self.vao);
    }

    pub fn uploadFrame(self: *Renderer, frame: *const [SCREEN_W * SCREEN_H]u32) void {
        c.glBindTexture(c.GL_TEXTURE_2D, self.texture);
        c.glTexSubImage2D(c.GL_TEXTURE_2D, 0, 0, 0, SCREEN_W, SCREEN_H, c.GL_BGRA, c.GL_UNSIGNED_INT_8_8_8_8_REV, @ptrCast(frame));
        c.glBindTexture(c.GL_TEXTURE_2D, 0);
    }

    pub fn draw(self: *Renderer) void {
        c.glClear(c.GL_COLOR_BUFFER_BIT);

        const program = if (self.crt_enabled) self.crt_program else self.passthrough_program;
        c.glUseProgram(program);

        c.glActiveTexture(c.GL_TEXTURE0);
        c.glBindTexture(c.GL_TEXTURE_2D, self.texture);

        c.glBindVertexArray(self.vao);
        c.glDrawElements(c.GL_TRIANGLES, 6, c.GL_UNSIGNED_INT, @ptrFromInt(0));
        c.glBindVertexArray(0);
    }

    pub fn toggleCrt(self: *Renderer) void {
        self.crt_enabled = !self.crt_enabled;
        std.debug.print("DMG LCD shader: {s}\n", .{if (self.crt_enabled) "ON" else "OFF"});
    }

    fn compileShader(shader_type: c.GLenum, source: [*c]const u8) c.GLuint {
        const shader = c.glCreateShader(shader_type);
        c.glShaderSource(shader, 1, &source, null);
        c.glCompileShader(shader);

        var success: c.GLint = 0;
        c.glGetShaderiv(shader, c.GL_COMPILE_STATUS, &success);
        if (success == 0) {
            var info_log: [512]u8 = undefined;
            var log_len: c.GLsizei = 0;
            c.glGetShaderInfoLog(shader, 512, &log_len, &info_log);
            const len: usize = @intCast(log_len);
            std.debug.print("Shader compilation error: {s}\n", .{info_log[0..len]});
        }

        return shader;
    }

    fn createProgram(vert_src: [*c]const u8, frag_src: [*c]const u8) c.GLuint {
        const vert = compileShader(c.GL_VERTEX_SHADER, vert_src);
        const frag = compileShader(c.GL_FRAGMENT_SHADER, frag_src);

        const program = c.glCreateProgram();
        c.glAttachShader(program, vert);
        c.glAttachShader(program, frag);
        c.glLinkProgram(program);

        var success: c.GLint = 0;
        c.glGetProgramiv(program, c.GL_LINK_STATUS, &success);
        if (success == 0) {
            var info_log: [512]u8 = undefined;
            var log_len: c.GLsizei = 0;
            c.glGetProgramInfoLog(program, 512, &log_len, &info_log);
            const len: usize = @intCast(log_len);
            std.debug.print("Shader link error: {s}\n", .{info_log[0..len]});
        }

        c.glDeleteShader(vert);
        c.glDeleteShader(frag);

        return program;
    }
};
