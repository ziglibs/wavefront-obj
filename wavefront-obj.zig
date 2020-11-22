const std = @import("std");
const zlm = @import("zlm");

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

pub const Model = struct {
    const Self = @This();

    allocator: *std.mem.Allocator,
    arena: std.heap.ArenaAllocator,

    positions: []Vec4,
    normals: []Vec3,
    textureCoordinates: []Vec3,
    faces: []Face,
    objects: []Object,
    materials: std.StringHashMap(Material),

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.positions);
        self.allocator.free(self.normals);
        self.allocator.free(self.textureCoordinates);
        self.allocator.free(self.faces);
        self.allocator.free(self.objects);
        self.materials.deinit();
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

    var iter = std.mem.split(spec, "/");
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

pub fn loadFile(allocator: *std.mem.Allocator, path: []const u8) !Model {
    var file = try std.fs.File.openRead(path);
    defer file.close();

    return load(allocator, file.inStream());
}

pub fn load(allocator: *std.mem.Allocator, stream: anytype) !Model {
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

    var materials = std.StringHashMap(Material).init(allocator);
    errdefer materials.deinit();

    try positions.ensureCapacity(10_000);
    try normals.ensureCapacity(10_000);
    try textureCoordinates.ensureCapacity(10_000);
    try faces.ensureCapacity(10_000);
    try objects.ensureCapacity(100);

    // note:
    // this may look like a dangling pointer as ArrayList changes it's pointers when resized.
    // BUT: the pointer will be changed with the added element, so it will not dangle
    var currentObject: ?*Object = null;

    while (true) {
        var line: []const u8 = stream.readUntilDelimiterAlloc(allocator, '\n', 1024) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        defer allocator.free(line);

        line = std.mem.trim(u8, line, " \r\n\t");
        if (line.len == 0)
            continue;

        errdefer {
            std.debug.print("error parsing line: '{}'\n", .{
                line,
            });
        }

        // parse comments
        if (std.mem.startsWith(u8, line, "#")) {
            continue;
        }
        // parse vertex
        else if (std.mem.startsWith(u8, line, "v ")) {
            var iter = std.mem.split(line[2..], " ");
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
            var iter = std.mem.split(line[3..], " ");
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
            var iter = std.mem.split(line[3..], " ");
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
            var iter = std.mem.split(line[2..], " ");
            var state: u32 = 0;

            var vertices = std.ArrayList(Vertex).init(&arena.allocator);
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
            obj.name = arena.allocator.dupe(u8, line[2..]) catch |err| {
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
                    obj.* = try objects.addOne();
                    obj.*.start = faces.items.len;
                    obj.*.count = 0;
                    obj.*.name = arena.allocator.dupe(u8, current_name) catch |err| {
                        _ = objects.pop(); // remove last element, then error
                        return err;
                    };
                }

                obj.*.material = try arena.allocator.dupe(u8, line[7..]);
            } else {
                currentObject = try objects.addOne();
                currentObject.?.start = faces.items.len;
                currentObject.?.count = 0;
                currentObject.?.name = arena.allocator.dupe(u8, "unnamed") catch |err| {
                    _ = objects.pop(); // remove last element, then error
                    return err;
                };
            }
        }
        // parse smoothing groups
        else if (std.mem.startsWith(u8, line, "s ")) {
            // and just ignore them :(
        } else {
            std.debug.warn("read line: {}\n", .{line});
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

        .materials = materials,
    };
}
