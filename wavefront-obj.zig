const std = @import("std");
const zlm = @import("zlm");

const log = std.log.scoped(.wavefront_obj);

const vec2 = zlm.vec2;
const vec3 = zlm.vec3;
const vec4 = zlm.vec4;

const Vec2 = zlm.Vec2;
const Vec3 = zlm.Vec3;
const Vec4 = zlm.Vec4;

test "" {
    std.testing.refAllDecls(@This());
}

// this file parses OBJ wavefront according to
// http://paulbourke.net/dataformats/obj/
// with a lot of restrictions

pub const Vertex = struct {
    position: usize,
    normal: ?usize,
    textureCoordinate: ?usize,
};

pub const Face = struct {
    vertices: []Vertex,
};

pub const Object = struct {
    name: []const u8,
    material: ?[]const u8,
    start: usize,
    count: usize,
};

pub const Model = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,

    positions: []Vec4,
    normals: []Vec3,
    textureCoordinates: []Vec3,
    faces: []Face,
    objects: []Object,

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.positions);
        self.allocator.free(self.normals);
        self.allocator.free(self.textureCoordinates);
        self.allocator.free(self.faces);
        self.allocator.free(self.objects);
        self.arena.deinit();
        self.* = undefined;
    }
};

fn parseVertexSpec(spec: []const u8) !Vertex {
    var vertex = Vertex{
        .position = 0,
        .normal = null,
        .textureCoordinate = null,
    };

    var iter = std.mem.split(u8, spec, "/");
    var state: u32 = 0;
    while (iter.next()) |part| {
        switch (state) {
            0 => vertex.position = (try std.fmt.parseInt(usize, part, 10)) - 1,
            1 => vertex.textureCoordinate = if (!std.mem.eql(u8, part, "")) (try std.fmt.parseInt(usize, part, 10)) - 1 else null,
            2 => vertex.normal = if (!std.mem.eql(u8, part, "")) (try std.fmt.parseInt(usize, part, 10)) - 1 else null,
            else => return error.InvalidFormat,
        }
        state += 1;
    }

    return vertex;
}

pub fn loadFile(allocator: std.mem.Allocator, path: []const u8) !Model {
    var file = try std.fs.cwd().openFile(path, .{ .mode = .read_only });
    defer file.close();

    return load(allocator, file.reader());
}

pub fn load(
    allocator: std.mem.Allocator,
    stream: anytype,
) !Model {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();

    var positions = std.ArrayList(Vec4).init(allocator);
    defer positions.deinit();
    var normals = std.ArrayList(Vec3).init(allocator);
    defer normals.deinit();
    var textureCoordinates = std.ArrayList(Vec3).init(allocator);
    defer textureCoordinates.deinit();
    var faces = std.ArrayList(Face).init(allocator);
    defer faces.deinit();
    var objects = std.ArrayList(Object).init(allocator);
    defer objects.deinit();

    try positions.ensureTotalCapacity(10_000);
    try normals.ensureTotalCapacity(10_000);
    try textureCoordinates.ensureTotalCapacity(10_000);
    try faces.ensureTotalCapacity(10_000);
    try objects.ensureTotalCapacity(100);

    // note:
    // this may look like a dangling pointer as ArrayList changes it's pointers when resized.
    // BUT: the pointer will be changed with the added element, so it will not dangle
    var currentObject: ?*Object = null;

    var line_reader = lineIterator(allocator, stream);
    defer line_reader.deinit();

    while (try line_reader.next()) |line| {
        errdefer {
            log.err("error parsing line: '{s}'", .{
                line,
            });
        }

        // parse vertex
        if (std.mem.startsWith(u8, line, "v ")) {
            var iter = std.mem.tokenize(u8, line[2..], " ");
            var state: u32 = 0;
            var vertex = vec4(0, 0, 0, 1);
            while (iter.next()) |part| {
                switch (state) {
                    0 => vertex.x = try std.fmt.parseFloat(f32, part),
                    1 => vertex.y = try std.fmt.parseFloat(f32, part),
                    2 => vertex.z = try std.fmt.parseFloat(f32, part),
                    3 => vertex.w = try std.fmt.parseFloat(f32, part),
                    else => return error.InvalidFormat,
                }
                state += 1;
            }
            if (state < 3) // v x y z w, with x,y,z are required, w is optional
                return error.InvalidFormat;
            try positions.append(vertex);
        }
        // parse uv coords
        else if (std.mem.startsWith(u8, line, "vt ")) {
            var iter = std.mem.tokenize(u8, line[3..], " ");
            var state: u32 = 0;
            var texcoord = vec3(0, 0, 0);
            while (iter.next()) |part| {
                switch (state) {
                    0 => texcoord.x = try std.fmt.parseFloat(f32, part),
                    1 => texcoord.y = try std.fmt.parseFloat(f32, part),
                    2 => texcoord.z = try std.fmt.parseFloat(f32, part),
                    else => return error.InvalidFormat,
                }
                state += 1;
            }
            if (state < 1) // vt u v w, with u is required, v and w are optional
                return error.InvalidFormat;
            try textureCoordinates.append(texcoord);
        }
        // parse normals
        else if (std.mem.startsWith(u8, line, "vn ")) {
            var iter = std.mem.tokenize(u8, line[3..], " ");
            var state: u32 = 0;
            var normal = vec3(0, 0, 0);
            while (iter.next()) |part| {
                switch (state) {
                    0 => normal.x = try std.fmt.parseFloat(f32, part),
                    1 => normal.y = try std.fmt.parseFloat(f32, part),
                    2 => normal.z = try std.fmt.parseFloat(f32, part),
                    else => return error.InvalidFormat,
                }
                state += 1;
            }
            if (state < 3) // vn i j k, with i,j,k are required, none are optional
                return error.InvalidFormat;
            try normals.append(normal);
        }
        // parse faces
        else if (std.mem.startsWith(u8, line, "f ")) {
            var iter = std.mem.tokenize(u8, line[2..], " ");
            var state: u32 = 0;

            var vertices = std.ArrayList(Vertex).init(arena.allocator());
            defer vertices.deinit();

            while (iter.next()) |part| {
                const vert = try parseVertexSpec(part);
                try vertices.append(vert);
                state += 1;
            }
            if (vertices.items.len < 3) // less than 3 faces is an error (no line or point support)
                return error.InvalidFormat;

            try faces.append(Face{
                .vertices = vertices.toOwnedSlice(),
            });
        }
        // parse objects
        else if (std.mem.startsWith(u8, line, "o ")) {
            if (currentObject) |obj| {
                // terminate object
                obj.count = faces.items.len - obj.start;
            }
            var obj = try objects.addOne();

            obj.start = faces.items.len;
            obj.count = 0;
            obj.name = arena.allocator().dupe(u8, line[2..]) catch |err| {
                _ = objects.pop(); // remove last element, then error
                return err;
            };

            currentObject = obj;
        }
        // parse material libraries
        else if (std.mem.startsWith(u8, line, "mtllib ")) {
            // ignore material libraries for now...
            // TODO: Implement material libraries
        }
        // parse material application
        else if (std.mem.startsWith(u8, line, "usemtl ")) {
            if (currentObject) |*obj| {
                if (obj.*.material != null) {
                    // duplicate object when two materials per object
                    const current_name = obj.*.name;

                    // terminate object
                    obj.*.count = faces.items.len - obj.*.start;

                    obj.* = try objects.addOne();
                    obj.*.start = faces.items.len;
                    obj.*.count = 0;
                    obj.*.name = arena.allocator().dupe(u8, current_name) catch |err| {
                        _ = objects.pop(); // remove last element, then error
                        return err;
                    };
                }

                obj.*.material = try arena.allocator().dupe(u8, line[7..]);
            } else {
                currentObject = try objects.addOne();
                currentObject.?.start = faces.items.len;
                currentObject.?.count = 0;
                currentObject.?.name = arena.allocator().dupe(u8, "unnamed") catch |err| {
                    _ = objects.pop(); // remove last element, then error
                    return err;
                };

                currentObject.?.material = try arena.allocator().dupe(u8, line[7..]);
            }
        }
        // parse smoothing groups
        else if (std.mem.startsWith(u8, line, "s ")) {
            // and just ignore them :(
        } else {
            log.warn("unrecognized line: {s}", .{line});
        }
    }

    // terminate object if any
    if (currentObject) |obj| {
        obj.count = faces.items.len - obj.start;
    }

    return Model{
        .allocator = allocator,
        .arena = arena,

        .positions = positions.toOwnedSlice(),
        .normals = normals.toOwnedSlice(),
        .textureCoordinates = textureCoordinates.toOwnedSlice(),
        .faces = faces.toOwnedSlice(),
        .objects = objects.toOwnedSlice(),
    };
}

pub const Color = struct {
    r: f32,
    g: f32,
    b: f32,
};

pub const Material = struct {
    ambient_texture: ?[]const u8 = null,
    diffuse_texture: ?[]const u8 = null,
    specular_texture: ?[]const u8 = null,

    ambient_color: ?Color = null,
    diffuse_color: ?Color = null,
    specular_color: ?Color = null,
};

pub const MaterialLibrary = struct {
    const Self = @This();

    arena: std.heap.ArenaAllocator,
    materials: std.StringHashMap(Material),

    pub fn deinit(self: *Self) void {
        self.materials.deinit();
        self.arena.deinit();
        self.* = undefined;
    }
};

pub fn loadMaterials(allocator: *std.mem.Allocator, stream: anytype) !MaterialLibrary {
    var materials = std.StringHashMap(Material).init(allocator);
    errdefer materials.deinit();

    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();

    var line_reader = lineIterator(allocator, stream);
    defer line_reader.deinit();

    var current_mtl: ?*Material = null;

    while (try line_reader.next()) |line| {
        errdefer {
            log.err("error parsing line: '{s}'\n", .{
                line,
            });
        }

        if (std.mem.startsWith(u8, line, "newmtl ")) {
            const mtl_name = try arena.allocator.dupe(u8, line[7..]);

            const gop = try materials.getOrPut(mtl_name);
            if (gop.found_existing) {
                log.err("duplicate material name: '{s}'", .{mtl_name});
                return error.DuplicateMaterial;
            }

            gop.entry.value = Material{};
            current_mtl = &gop.entry.value;
        } else if (std.mem.startsWith(u8, line, "Ka ")) {
            if (current_mtl) |mtl| {
                mtl.ambient_color = try parseColor(line[3..]);
            } else {
                log.err("missing newmtl!", .{});
                return error.InvalidFormat;
            }
        } else if (std.mem.startsWith(u8, line, "Kd ")) {
            if (current_mtl) |mtl| {
                mtl.diffuse_color = try parseColor(line[3..]);
            } else {
                log.err("missing newmtl!", .{});
                return error.InvalidFormat;
            }
        } else if (std.mem.startsWith(u8, line, "Ks ")) {
            if (current_mtl) |mtl| {
                mtl.specular_color = try parseColor(line[3..]);
            } else {
                log.err("missing newmtl!", .{});
                return error.InvalidFormat;
            }
        } else if (std.mem.startsWith(u8, line, "map_Ka")) {
            if (current_mtl) |mtl| {
                mtl.ambient_texture = try arena.allocator.dupe(u8, std.mem.trim(u8, line[7..], " \t\r\n"));
            } else {
                log.err("missing newmtl!", .{});
                return error.InvalidFormat;
            }
        } else if (std.mem.startsWith(u8, line, "map_Kd")) {
            if (current_mtl) |mtl| {
                mtl.diffuse_texture = try arena.allocator.dupe(u8, std.mem.trim(u8, line[7..], " \t\r\n"));
            } else {
                log.err("missing newmtl!", .{});
                return error.InvalidFormat;
            }
        } else if (std.mem.startsWith(u8, line, "map_Ks")) {
            if (current_mtl) |mtl| {
                mtl.specular_texture = try arena.allocator.dupe(u8, std.mem.trim(u8, line[7..], " \t\r\n"));
            } else {
                log.err("missing newmtl!", .{});
                return error.InvalidFormat;
            }
        } else {
            log.warn("unrecognized line: '{s}'", .{line});
        }
    }

    return MaterialLibrary{
        .arena = arena,
        .materials = materials,
    };
}

fn parseColor(line: []const u8) !Color {
    var iterator = std.mem.tokenize(line, " ");

    var result = Color{
        .r = undefined,
        .g = undefined,
        .b = undefined,
    };

    var index: usize = 0;
    while (iterator.next()) |tok| : (index += 1) {
        switch (index) {
            0 => result.r = try std.fmt.parseFloat(f32, tok),
            1 => result.g = try std.fmt.parseFloat(f32, tok),
            2 => result.b = try std.fmt.parseFloat(f32, tok),
            else => return error.InvalidFormat,
        }
    }
    if (index < 3)
        return error.InvalidFormat;
    return result;
}

fn LineIterator(comptime Reader: type) type {
    return struct {
        const Self = @This();

        reader: Reader,
        buffer: std.ArrayList(u8),

        pub fn deinit(self: *Self) void {
            self.buffer.deinit();
            self.* = undefined;
        }

        pub fn next(self: *Self) !?[]const u8 {
            while (true) {
                self.reader.readUntilDelimiterArrayList(&self.buffer, '\n', 4096) catch |err| switch (err) {
                    error.EndOfStream => return null,
                    else => return err,
                };

                var line: []const u8 = self.buffer.items;

                // remove comments
                if (std.mem.indexOf(u8, line, "#")) |idx| {
                    line = line[0..idx];
                }

                // strip trailing/leading whites
                line = std.mem.trim(u8, line, " \r\n\t");
                if (line.len == 0) {
                    continue;
                }
                return line;
            }
        }
    };
}

fn lineIterator(allocator: std.mem.Allocator, reader: anytype) LineIterator(@TypeOf(reader)) {
    return LineIterator(@TypeOf(reader)){
        .reader = reader,
        .buffer = std.ArrayList(u8).init(allocator),
    };
}
