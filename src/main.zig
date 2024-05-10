const rl = @import("raylib.zig");
const std = @import("std");

const GameConfig = struct {
    window_side_factor: i32,
    window_width_scaler: i32,
    window_height_scaler: i32,
    window_name: [*c]const u8 = "Tetris",

    targetFPS: i32 = 60,

    cell_size: i32,
    cell_outline_color: rl.Color,

    outline_thickness: f32,

    background_color: rl.Color,
    grid_color: rl.Color,

    fn getWindowWidth(self: *const GameConfig) i32 {
        return self.window_width_scaler * self.window_side_factor;
    }


        fn getWindowHeight(self: *const GameConfig) i32 {
        return self.window_height_scaler * self.window_side_factor;
    }
};

var gameConfig = GameConfig{
    .window_side_factor = 50,
    .window_width_scaler = 9,
    .window_height_scaler = 16,
    .cell_size = 0, // evaluated in initGame
    .cell_outline_color = rl.SKYBLUE,
    .outline_thickness = 1,
    .background_color = rl.RAYWHITE,
    .grid_color = rl.BLACK,
};

const GridPosition = struct {
    row: i32,
    col: i32
};

const AABB = struct {
    min_x: i32,
    min_y: i32,
    max_x: i32,
    max_y: i32,

    fn createFromBlockParts(parts: [4]BlockPart) AABB {
        var aabb = AABB{
            .min_x = std.math.maxInt(i32),
            .min_y = std.math.maxInt(i32),
            .max_x = std.math.minInt(i32),
            .max_y = std.math.minInt(i32),
        };

        for (parts) |part| {
            if (aabb.min_x < part.grid_position.col) aabb.min_x = part.grid_position.col;
            if (aabb.min_y < part.grid_position.row) aabb.min_y = part.grid_position.row;
            if (aabb.max_x > part.grid_position.col) aabb.max_x = part.grid_position.col;
            if (aabb.max_y > part.grid_position.row) aabb.max_y = part.grid_position.row;
        }
    }
};

const LocationInShape = enum(u4) { 
    left   = 0b0001,
    right  = 0b0010, 
    top    = 0b0100, 
    bottom = 0b1000,
};

const BlockPart = struct {
    grid_position: GridPosition,
    loc_in_shape: u4,
};

const Grid = struct {
    cells: []bool,
    rows: i32,
    cols: i32,

    hanging_empty_rows: []usize,
    hanging_rows_count: usize,

    screen_position: Vector2,

    allocator: *std.mem.Allocator,

    fn new(allocator: *std.mem.Allocator, rows: i32, cols: i32, screen_position: Vector2) !Grid {
        const cells = try allocator.alloc(bool, @intCast(rows * cols));
        errdefer allocator.free(cells);

        const hanging_empty_rows = try allocator.alloc(usize, @intCast(rows));
        errdefer allocator.free(hanging_empty_rows);

        const grid = Grid{
            .cells = cells,
            .rows = rows,
            .cols = cols,
            .hanging_empty_rows = hanging_empty_rows,
            .hanging_rows_count = 0,
            .screen_position = screen_position,
            .allocator = allocator,
        };
        @memset(grid.cells, false);
        @memset(grid.hanging_empty_rows, 0);

        return grid;
    }

    fn destroy(self: *Grid) void {
        self.allocator.free(self.cells);
    }

    fn indexOfCell(self: *const Grid, cell: GridPosition) usize {
        return @intCast(cell.row * self.cols + cell.col);
    }

    fn tryFillSingleHangingRow(self: *Grid) void {
        if (self.hanging_rows_count == 0) return;

        self.hanging_rows_count -= 1;
        const row = self.hanging_empty_rows[self.hanging_rows_count];
        self.hanging_empty_rows[self.hanging_rows_count] = @intCast(self.rows); // instead of nulling it, actually it should not be accessed

        if (row == 0) return;

        var r: usize = row + 1;
        while (r > 0) {
            r -= 1;

            var something_was_moved = false;
            for (0..@as(usize, @intCast(self.cols))) |c| {
                const index_curr = self.indexOfCell(GridPosition{.row = @intCast(r), .col = @intCast(c)});
                const index_above = self.indexOfCell(GridPosition{.row = @intCast(r - 1), .col = @intCast(c)});
                if (self.cells[index_above]) {
                    self.cells[index_above] = false;
                    self.cells[index_curr] = true;
                    something_was_moved = true;
                }
            }

            if (!something_was_moved) return;
        }
    }

    fn clearFilledRows(self: *Grid) void {
        var r: usize = @intCast(self.rows);
        while (r > 0) {
            r -= 1;

            var clear_row = true;
            for (0..@as(usize, @intCast(self.cols))) |c| {
                const index = self.indexOfCell(GridPosition{.row = @intCast(r), .col = @intCast(c)});
                if (!self.cells[index]) {
                    clear_row = false;
                    break;
                }
            }

            if (clear_row) {
                self.hanging_empty_rows[self.hanging_rows_count] = @intCast(r);
                self.hanging_rows_count += 1;
                for (0..@as(usize, @intCast(self.cols))) |c| {
                    const index = self.indexOfCell(GridPosition{.row = @intCast(r), .col = @intCast(c)});
                    self.cells[index] = false;
                }
            }
        }
    }

    fn fillCells(self: *Grid, cells: []const GridPosition) void {
        for (cells) |cell| {
            const index = self.indexOfCell(cell);
            self.cells[index] = true;
        }

        self.clearFilledRows();
    }

    fn clearCells(self: *Grid, cells: []const GridPosition) void {
        for (cells) |cell| {
            const index = self.indexOfCell(cell);
            self.cells[index] = false;
        }
    }

    fn draw(self: *const Grid) void {
        for (0..@as(usize, @intCast(self.rows))) |r| {
            for (0..@as(usize, @intCast(self.cols))) |c| {
                const index = self.indexOfCell(GridPosition{.row = @intCast(r), .col = @intCast(c)});
                if (self.cells[index]) {
                    self.drawFilledCell(@intCast(r), @intCast(c));
                }
            }
        }


        {
            const outline_delta = gameConfig.outline_thickness * 0.5;
            var i: i32 = 0;
            while (i < self.rows + 1) {
                const startPos = Vector2{
                    .x = self.screen_position.x + outline_delta,
                    .y = self.screen_position.y + outline_delta + @as(f32, @floatFromInt(i * gameConfig.cell_size)),
                };
                const endPos = Vector2{
                    .x = startPos.x + @as(f32, @floatFromInt(self.cols * gameConfig.cell_size)),
                    .y = startPos.y,
                };

                rl.DrawLineEx(startPos.toRl(), endPos.toRl(), 2, rl.GRAY);


                i += 1;
            }
        }

        {
            const outline_delta = gameConfig.outline_thickness * 0.5;
            var i: i32 = 0;
            while (i < self.cols + 1) {
                const startPos = Vector2{
                    .x = self.screen_position.x + outline_delta + @as(f32, @floatFromInt(i * gameConfig.cell_size)),
                    .y = self.screen_position.y + outline_delta,
                };
                const endPos = Vector2{
                    .x = startPos.x,
                    .y = startPos.y + @as(f32, @floatFromInt(self.rows * gameConfig.cell_size)),
                };

                rl.DrawLineEx(startPos.toRl(), endPos.toRl(), 2, gameConfig.grid_color);


                i += 1;
            }
        }

    }

    fn drawFilledCell(self: *const Grid, row: i32, col: i32) void {
        const rec = rl.Rectangle{
            .x = self.screen_position.x + @as(f32, @floatFromInt(col * gameConfig.cell_size)),
            .y = self.screen_position.y + @as(f32, @floatFromInt(row * gameConfig.cell_size)),
            .width =  @as(f32, @floatFromInt(gameConfig.cell_size)),
            .height = @as(f32, @floatFromInt(gameConfig.cell_size)),
        };
        rl.DrawRectangleRec(rec, rl.BLUE);
    }

    fn getScreenX(self: *Grid, x: i32) f32 {
        return self.screen_position.x + @as(f32, @floatFromInt(x * gameConfig.cell_size));
    }

    fn getScreenY(self: *Grid, y: i32) f32 {
        return self.screen_position.y + @as(f32, @floatFromInt(y * gameConfig.cell_size));
    }

    fn rotateBlockIfPossible(self: *const Grid, block: *Block) void {
        var b = block.*;
        b.rotate();
        const parts = b.getAllParts();

        for (parts) |part| {
            if (part.grid_position.col < 0 or part.grid_position.col >= self.cols
                or part.grid_position.row < 0 or part.grid_position.row >= self.rows
                or self.cells[self.indexOfCell(part.grid_position)]) {
                return;
            }
        }

        block.* = b;
    }

    fn blockCanMove(self: *const Grid, block: *const Block, direction: Direction) bool {
        switch (direction) {
            Direction.up => {
                return false;
            },
            Direction.down => {
                const parts = block.getAllParts();
                for (parts) |part| {
                    if (0 == (part.loc_in_shape & @intFromEnum(LocationInShape.bottom))) continue;

                    var cell = part.grid_position;
                    cell.row += 1;
                    if (cell.row == self.rows or self.cells[self.indexOfCell(cell)]) {
                        return false;
                    }
                }
            },
            Direction.left => {
                const parts = block.getAllParts();
                for (parts) |part| {
                    if (0 == (part.loc_in_shape & @intFromEnum(LocationInShape.left))) continue;

                    var cell = part.grid_position;
                    cell.col -= 1;
                    if (cell.col == -1 or self.cells[self.indexOfCell(cell)]) {
                        return false;
                    }
                }
            },
            Direction.right => {
                const parts = block.getAllParts();
                for (parts) |part| {
                    if (0 == (part.loc_in_shape & @intFromEnum(LocationInShape.right))) continue;

                    var cell = part.grid_position;
                    cell.col += 1;
                    if (cell.col == self.cols or self.cells[self.indexOfCell(cell)]) {
                        return false;
                    }
                }
            },

        }

        return true;
    }
};

const GameState = struct {
    grid:             Grid,
    active_block:      ?Block = null,
    next_block_shape: BlockShape,
    time_to_tick:       f32 = 0.5,
    tick_time:         f32 = 0.5,
    original_tick_time: f32 = 0.5,

    fn createBlock(self: *GameState) void {
        const colors = [_]rl.Color{
            rl.RED, rl.GREEN, rl.YELLOW, rl.PINK
        };

        const block = Block{
            .shape = self.next_block_shape,
            .position = GridPosition{.row = 0, .col = @divFloor(self.grid.cols, 2) - 1 },
            .fillColor = colors[@intCast(rl.GetRandomValue(0, colors.len - 1))],
            .n_rotations = 0,
        };

        self.active_block = block;

        self.next_block_shape = @enumFromInt(rl.GetRandomValue(0, @typeInfo(BlockShape).Enum.fields.len - 1));
    }

    fn draw(self: *const GameState) void {
        self.grid.draw();

        if (self.active_block) |b| {
            b.draw();
        }
    }

    fn resetTicker(self: *GameState) void {
        self.time_to_tick = self.tick_time;
    }
};

var gameState: GameState = undefined;
var main_allocator: std.mem.Allocator = undefined;

const Direction = enum { up, down, left, right, };

const Vector2 = struct {
    x: f32 = 0,
    y: f32 = 0,

    fn toRl(self: *const Vector2) rl.Vector2 {
        return rl.Vector2{ .x = self.x, .y = self.y };
    }

    fn equals(self: *const Vector2, other: *const Vector2) bool {
        return self.x == other.x and self.y == other.y;
    }

    fn add(a: Vector2, b: Vector2) Vector2 {
        return Vector2{ .x = a.x + b.x, .y = a.y + b.y };
    }

    fn sub(a: Vector2, b: Vector2) Vector2 {
        return Vector2{ .x = a.x - b.x, .y = a.y - b.y };
    }


    fn down() Vector2 {
        return Vector2{ .x = 0, .y = 1 };
    }

    fn up() Vector2 {
        return Vector2{ .x = 0, .y = -1 };
    }

    fn right() Vector2 {
        return Vector2{ .x = 1, .y = 0 };
    }

    fn left() Vector2 {
        return Vector2{ .x = -1, .y = 0 };
    }

    fn zero() Vector2 {
        return Vector2{ .x = 0, .y = 0 };
    }
};

const BlockShape = enum(u8) {
    O = 0, I = 1, S = 2, Z = 3, L = 4, J= 5, T = 6,
};

const Block = struct {
    shape:       BlockShape,
    position:    GridPosition, // top left corner in the grid
    fillColor:   rl.Color,
    n_rotations: u2,

    fn move(self: *Block, direction: Direction) void {
        switch (direction) {
            Direction.up    => unreachable,
            Direction.down  => self.position.row += 1,
            Direction.left  => self.position.col -= 1,
            Direction.right => self.position.col += 1,
        }
    }

    fn rotate(self: *Block) void {
        self.n_rotations +%= 1;
    }

    fn draw(self: *const Block) void {
        var rec = rl.Rectangle{
            .x = 0,
            .y = 0,
            .width =  @as(f32, @floatFromInt(gameConfig.cell_size)),
            .height = @as(f32, @floatFromInt(gameConfig.cell_size)),
        };

        const cells = self.getAllCells();
        for (cells) |cell| {
            rec.x = gameState.grid.getScreenX(cell.col);
            rec.y = gameState.grid.getScreenY(cell.row);
            self.drawCellPart(rec);
        }
    }

    fn drawCellPart(self: *const Block, rec: rl.Rectangle) void {
        rl.DrawRectangleRec(rec, self.fillColor);
        rl.DrawRectangleLinesEx(rec, gameConfig.outline_thickness, gameConfig.cell_outline_color);
    }

    fn getAllCells(self: *const Block) [4]GridPosition {
        const parts = self.getAllParts();
        var cells: [4]GridPosition = undefined;
        inline for (parts, 0..) |part, i| {
            cells[i] = part.grid_position;
        }
        return cells;
    }

    fn getAllParts(self: *const Block) [4]BlockPart {
        switch (self.shape) {
            BlockShape.O => { 
                const loc0 = @intFromEnum(LocationInShape.left)  | @intFromEnum(LocationInShape.top);
                const loc1 = @intFromEnum(LocationInShape.right) | @intFromEnum(LocationInShape.top);
                const loc2 = @intFromEnum(LocationInShape.left)  | @intFromEnum(LocationInShape.bottom);
                const loc3 = @intFromEnum(LocationInShape.right) | @intFromEnum(LocationInShape.bottom);

                return [4]BlockPart {
                    BlockPart{
                        .grid_position = GridPosition{
                            .col = self.position.col + 0,
                            .row = self.position.row + 0,
                        },
                        .loc_in_shape = loc0,
                    }, 
                    BlockPart{
                        .grid_position = GridPosition {
                            .col = self.position.col + 1,
                            .row = self.position.row + 0,
                        },
                        .loc_in_shape = loc1,
                    }, 
                    BlockPart{
                        .grid_position = GridPosition {
                            .col = self.position.col + 0,
                            .row = self.position.row + 1,
                        },
                        .loc_in_shape = loc2,
                    }, 
                    BlockPart{
                        .grid_position = GridPosition {
                            .col = self.position.col + 1,
                            .row = self.position.row + 1,
                        },
                        .loc_in_shape = loc3,
                    }, 
                };
            },
            BlockShape.I => {
                switch (self.n_rotations) {
                    0, 2 => {
                        const loc0 = @intFromEnum(LocationInShape.left)  | @intFromEnum(LocationInShape.top)
                            | @intFromEnum(LocationInShape.right);
                        const loc1 = @intFromEnum(LocationInShape.left)  | @intFromEnum(LocationInShape.right);
                        const loc2 = @intFromEnum(LocationInShape.left)  | @intFromEnum(LocationInShape.right);
                        const loc3 = @intFromEnum(LocationInShape.left) | @intFromEnum(LocationInShape.bottom)
                            | @intFromEnum(LocationInShape.right);

                        return [4]BlockPart {
                            BlockPart{
                                .grid_position = GridPosition{
                                    .col = self.position.col + 0,
                                    .row = self.position.row + 0,
                                },
                                .loc_in_shape = loc0,
                            }, 
                            BlockPart{
                                .grid_position = GridPosition {
                                    .col = self.position.col + 0,
                                    .row = self.position.row + 1,
                                },
                                .loc_in_shape = loc1,
                            }, 
                            BlockPart{
                                .grid_position = GridPosition {
                                    .col = self.position.col + 0,
                                    .row = self.position.row + 2,
                                },
                                .loc_in_shape = loc2,
                            }, 
                            BlockPart{
                                .grid_position = GridPosition {
                                    .col = self.position.col + 0,
                                    .row = self.position.row + 3,
                                },
                                .loc_in_shape = loc3,
                            }, 
                        };
                    },
                    1, 3 => {
                        const loc0 = @intFromEnum(LocationInShape.left)  | @intFromEnum(LocationInShape.top)
                            | @intFromEnum(LocationInShape.bottom);
                        const loc1 = @intFromEnum(LocationInShape.top)  | @intFromEnum(LocationInShape.bottom);
                        const loc2 = @intFromEnum(LocationInShape.top)  | @intFromEnum(LocationInShape.bottom);
                        const loc3 = @intFromEnum(LocationInShape.right) | @intFromEnum(LocationInShape.top)
                            | @intFromEnum(LocationInShape.bottom);

                        return [4]BlockPart {
                            BlockPart{
                                .grid_position = GridPosition{
                                    .col = self.position.col + 0,
                                    .row = self.position.row + 0,
                                },
                                .loc_in_shape = loc0,
                            }, 
                            BlockPart{
                                .grid_position = GridPosition {
                                    .col = self.position.col + 1,
                                    .row = self.position.row + 0,
                                },
                                .loc_in_shape = loc1,
                            }, 
                            BlockPart{
                                .grid_position = GridPosition {
                                    .col = self.position.col + 2,
                                    .row = self.position.row + 0,
                                },
                                .loc_in_shape = loc2,
                            }, 
                            BlockPart{
                                .grid_position = GridPosition {
                                    .col = self.position.col + 3,
                                    .row = self.position.row + 0,
                                },
                                .loc_in_shape = loc3,
                            }, 
                        };
                    },
                }
            },
            BlockShape.S => {
                //  -- |  
                // --  | |
                //       |

                switch (self.n_rotations) {
                    0, 2 => {
                        const loc0 = @intFromEnum(LocationInShape.left) | @intFromEnum(LocationInShape.bottom)
                            | @intFromEnum(LocationInShape.top);
                        const loc1 = @intFromEnum(LocationInShape.right) | @intFromEnum(LocationInShape.bottom);
                        const loc2 = @intFromEnum(LocationInShape.left) | @intFromEnum(LocationInShape.top);
                        const loc3 = @intFromEnum(LocationInShape.right) | @intFromEnum(LocationInShape.bottom)
                            | @intFromEnum(LocationInShape.top);

                        return [4]BlockPart {
                            BlockPart{
                                .grid_position = GridPosition{
                                    .col = self.position.col + 0,
                                    .row = self.position.row + 1,
                                },
                                .loc_in_shape = loc0,
                            }, 
                            BlockPart{
                                .grid_position = GridPosition {
                                    .col = self.position.col + 1,
                                    .row = self.position.row + 1,
                                },
                                .loc_in_shape = loc1,
                            }, 
                            BlockPart{
                                .grid_position = GridPosition {
                                    .col = self.position.col + 1,
                                    .row = self.position.row + 0,
                                },
                                .loc_in_shape = loc2,
                            }, 
                            BlockPart{
                                .grid_position = GridPosition {
                                    .col = self.position.col + 2,
                                    .row = self.position.row + 0,
                                },
                                .loc_in_shape = loc3,
                            }, 
                        };
                    },
                    1, 3 => {
                        const loc0 = @intFromEnum(LocationInShape.left) | @intFromEnum(LocationInShape.top)
                            | @intFromEnum(LocationInShape.top);
                        const loc1 = @intFromEnum(LocationInShape.left) | @intFromEnum(LocationInShape.bottom);
                        const loc2 = @intFromEnum(LocationInShape.right) | @intFromEnum(LocationInShape.top);
                        const loc3 = @intFromEnum(LocationInShape.left) | @intFromEnum(LocationInShape.bottom)
                            | @intFromEnum(LocationInShape.right);

                        return [4]BlockPart {
                            BlockPart{
                                .grid_position = GridPosition{
                                    .col = self.position.col + 0,
                                    .row = self.position.row + 0,
                                },
                                .loc_in_shape = loc0,
                            }, 
                            BlockPart{
                                .grid_position = GridPosition {
                                    .col = self.position.col + 0,
                                    .row = self.position.row + 1,
                                },
                                .loc_in_shape = loc1,
                            }, 
                            BlockPart{
                                .grid_position = GridPosition {
                                    .col = self.position.col + 1,
                                    .row = self.position.row + 1,
                                },
                                .loc_in_shape = loc2,
                            }, 
                            BlockPart{
                                .grid_position = GridPosition {
                                    .col = self.position.col + 1,
                                    .row = self.position.row + 2,
                                },
                                .loc_in_shape = loc3,
                            }, 
                        };
                    }
                }
            },
            BlockShape.Z => {
                // --      | 
                //  --   | |
                //       | 

                switch (self.n_rotations) {
                    0, 2 => {
                        const loc0 = @intFromEnum(LocationInShape.left) | @intFromEnum(LocationInShape.bottom)
                            | @intFromEnum(LocationInShape.top);
                        const loc1 = @intFromEnum(LocationInShape.right) | @intFromEnum(LocationInShape.top);
                        const loc2 = @intFromEnum(LocationInShape.left) | @intFromEnum(LocationInShape.bottom);
                        const loc3 = @intFromEnum(LocationInShape.right) | @intFromEnum(LocationInShape.bottom)
                            | @intFromEnum(LocationInShape.top);

                        return [4]BlockPart {
                            BlockPart{
                                .grid_position = GridPosition{
                                    .col = self.position.col + 0,
                                    .row = self.position.row + 0,
                                },
                                .loc_in_shape = loc0,
                            }, 
                            BlockPart{
                                .grid_position = GridPosition {
                                    .col = self.position.col + 1,
                                    .row = self.position.row + 0,
                                },
                                .loc_in_shape = loc1,
                            }, 
                            BlockPart{
                                .grid_position = GridPosition {
                                    .col = self.position.col + 1,
                                    .row = self.position.row + 1,
                                },
                                .loc_in_shape = loc2,
                            }, 
                            BlockPart{
                                .grid_position = GridPosition {
                                    .col = self.position.col + 2,
                                    .row = self.position.row + 1,
                                },
                                .loc_in_shape = loc3,
                            }, 
                        };
                    },
                    1, 3 => {
                        const loc0 = @intFromEnum(LocationInShape.left) | @intFromEnum(LocationInShape.top)
                            | @intFromEnum(LocationInShape.right);
                        const loc1 = @intFromEnum(LocationInShape.right) | @intFromEnum(LocationInShape.bottom);
                        const loc2 = @intFromEnum(LocationInShape.left) | @intFromEnum(LocationInShape.top);
                        const loc3 = @intFromEnum(LocationInShape.left) | @intFromEnum(LocationInShape.right)
                            | @intFromEnum(LocationInShape.bottom);

                        return [4]BlockPart {
                            BlockPart{
                                .grid_position = GridPosition{
                                    .col = self.position.col + 1,
                                    .row = self.position.row + 0,
                                },
                                .loc_in_shape = loc0,
                            }, 
                            BlockPart{
                                .grid_position = GridPosition {
                                    .col = self.position.col + 1,
                                    .row = self.position.row + 1,
                                },
                                .loc_in_shape = loc1,
                            }, 
                            BlockPart{
                                .grid_position = GridPosition {
                                    .col = self.position.col + 0,
                                    .row = self.position.row + 1,
                                },
                                .loc_in_shape = loc2,
                            }, 
                            BlockPart{
                                .grid_position = GridPosition {
                                    .col = self.position.col + 0,
                                    .row = self.position.row + 2,
                                },
                                .loc_in_shape = loc3,
                            }, 
                        };
                    },
                }

                
            },
            BlockShape.L => {
                //             _
                // |    ___|    |   ___
                // |            |  |
                // |_           |

                switch (self.n_rotations) {
                    0 => {
                        const loc0 = @intFromEnum(LocationInShape.left) | @intFromEnum(LocationInShape.top)
                            | @intFromEnum(LocationInShape.right);
                        const loc1 = @intFromEnum(LocationInShape.left) | @intFromEnum(LocationInShape.right);
                        const loc2 = @intFromEnum(LocationInShape.left) | @intFromEnum(LocationInShape.bottom);
                        const loc3 = @intFromEnum(LocationInShape.right) | @intFromEnum(LocationInShape.bottom)
                            | @intFromEnum(LocationInShape.top);

                        return [4]BlockPart {
                            BlockPart{
                                .grid_position = GridPosition{
                                    .col = self.position.col + 0,
                                    .row = self.position.row + 0,
                                },
                                .loc_in_shape = loc0,
                            }, 
                            BlockPart{
                                .grid_position = GridPosition {
                                    .col = self.position.col + 0,
                                    .row = self.position.row + 1,
                                },
                                .loc_in_shape = loc1,
                            }, 
                            BlockPart{
                                .grid_position = GridPosition {
                                    .col = self.position.col + 0,
                                    .row = self.position.row + 2,
                                },
                                .loc_in_shape = loc2,
                            }, 
                            BlockPart{
                                .grid_position = GridPosition {
                                    .col = self.position.col + 1,
                                    .row = self.position.row + 2,
                                },
                                .loc_in_shape = loc3,
                            }, 
                        };
                    },
                    1 => {
                        const loc0 = @intFromEnum(LocationInShape.left) | @intFromEnum(LocationInShape.top)
                            | @intFromEnum(LocationInShape.bottom);
                        const loc1 = @intFromEnum(LocationInShape.top) | @intFromEnum(LocationInShape.bottom);
                        const loc2 = @intFromEnum(LocationInShape.right) | @intFromEnum(LocationInShape.bottom);
                        const loc3 = @intFromEnum(LocationInShape.left) | @intFromEnum(LocationInShape.top)
                            | @intFromEnum(LocationInShape.right);

                        return [4]BlockPart {
                            BlockPart{
                                .grid_position = GridPosition{
                                    .col = self.position.col + 0,
                                    .row = self.position.row + 1,
                                },
                                .loc_in_shape = loc0,
                            }, 
                            BlockPart{
                                .grid_position = GridPosition {
                                    .col = self.position.col + 1,
                                    .row = self.position.row + 1,
                                },
                                .loc_in_shape = loc1,
                            }, 
                            BlockPart{
                                .grid_position = GridPosition {
                                    .col = self.position.col + 2,
                                    .row = self.position.row + 1,
                                },
                                .loc_in_shape = loc2,
                            }, 
                            BlockPart{
                                .grid_position = GridPosition {
                                    .col = self.position.col + 2,
                                    .row = self.position.row + 0,
                                },
                                .loc_in_shape = loc3,
                            }, 
                        };
                    },
                    2 => {
                        const loc0 = @intFromEnum(LocationInShape.left) | @intFromEnum(LocationInShape.top)
                            | @intFromEnum(LocationInShape.bottom);
                        const loc1 = @intFromEnum(LocationInShape.right) | @intFromEnum(LocationInShape.top);
                        const loc2 = @intFromEnum(LocationInShape.left) | @intFromEnum(LocationInShape.right);
                        const loc3 = @intFromEnum(LocationInShape.left) | @intFromEnum(LocationInShape.right)
                            | @intFromEnum(LocationInShape.bottom);

                        return [4]BlockPart {
                            BlockPart{
                                .grid_position = GridPosition{
                                    .col = self.position.col + 0,
                                    .row = self.position.row + 0,
                                },
                                .loc_in_shape = loc0,
                            }, 
                            BlockPart{
                                .grid_position = GridPosition {
                                    .col = self.position.col + 1,
                                    .row = self.position.row + 0,
                                },
                                .loc_in_shape = loc1,
                            }, 
                            BlockPart{
                                .grid_position = GridPosition {
                                    .col = self.position.col + 1,
                                    .row = self.position.row + 1,
                                },
                                .loc_in_shape = loc2,
                            }, 
                            BlockPart{
                                .grid_position = GridPosition {
                                    .col = self.position.col + 1,
                                    .row = self.position.row + 2,
                                },
                                .loc_in_shape = loc3,
                            }, 
                        };
                    },
                    3 => {
                        const loc0 = @intFromEnum(LocationInShape.left) | @intFromEnum(LocationInShape.bottom)
                            | @intFromEnum(LocationInShape.right);
                        const loc1 = @intFromEnum(LocationInShape.left) | @intFromEnum(LocationInShape.top);
                        const loc2 = @intFromEnum(LocationInShape.top) | @intFromEnum(LocationInShape.bottom);
                        const loc3 = @intFromEnum(LocationInShape.right) | @intFromEnum(LocationInShape.bottom)
                            | @intFromEnum(LocationInShape.top);

                        return [4]BlockPart {
                            BlockPart{
                                .grid_position = GridPosition{
                                    .col = self.position.col + 0,
                                    .row = self.position.row + 1,
                                },
                                .loc_in_shape = loc0,
                            }, 
                            BlockPart{
                                .grid_position = GridPosition {
                                    .col = self.position.col + 0,
                                    .row = self.position.row + 0,
                                },
                                .loc_in_shape = loc1,
                            }, 
                            BlockPart{
                                .grid_position = GridPosition {
                                    .col = self.position.col + 1,
                                    .row = self.position.row + 0,
                                },
                                .loc_in_shape = loc2,
                            }, 
                            BlockPart{
                                .grid_position = GridPosition {
                                    .col = self.position.col + 2,
                                    .row = self.position.row + 0,
                                },
                                .loc_in_shape = loc3,
                            }, 
                        };
                    },
                }

                
            },
            BlockShape.J => {
                //               _
                //  |   ___     |   |___
                //  |      |    |   
                // _|           |

                switch (self.n_rotations) {
                    0 => {
                        const loc0 = @intFromEnum(LocationInShape.left) | @intFromEnum(LocationInShape.top)
                            | @intFromEnum(LocationInShape.right);
                        const loc1 = @intFromEnum(LocationInShape.left) | @intFromEnum(LocationInShape.right);
                        const loc2 = @intFromEnum(LocationInShape.right) | @intFromEnum(LocationInShape.bottom);
                        const loc3 = @intFromEnum(LocationInShape.left) | @intFromEnum(LocationInShape.bottom)
                            | @intFromEnum(LocationInShape.top);

                        return [4]BlockPart {
                            BlockPart{
                                .grid_position = GridPosition{
                                    .col = self.position.col + 1,
                                    .row = self.position.row + 0,
                                },
                                .loc_in_shape = loc0,
                            }, 
                            BlockPart{
                                .grid_position = GridPosition {
                                    .col = self.position.col + 1,
                                    .row = self.position.row + 1,
                                },
                                .loc_in_shape = loc1,
                            }, 
                            BlockPart{
                                .grid_position = GridPosition {
                                    .col = self.position.col + 1,
                                    .row = self.position.row + 2,
                                },
                                .loc_in_shape = loc2,
                            }, 
                            BlockPart{
                                .grid_position = GridPosition {
                                    .col = self.position.col + 0,
                                    .row = self.position.row + 2,
                                },
                                .loc_in_shape = loc3,
                            }, 
                        };
                    },
                    1 => {
                        const loc0 = @intFromEnum(LocationInShape.left) | @intFromEnum(LocationInShape.top)
                            | @intFromEnum(LocationInShape.bottom);
                        const loc1 = @intFromEnum(LocationInShape.top) | @intFromEnum(LocationInShape.bottom);
                        const loc2 = @intFromEnum(LocationInShape.right) | @intFromEnum(LocationInShape.top);
                        const loc3 = @intFromEnum(LocationInShape.left) | @intFromEnum(LocationInShape.bottom)
                            | @intFromEnum(LocationInShape.right);

                        return [4]BlockPart {
                            BlockPart{
                                .grid_position = GridPosition{
                                    .col = self.position.col + 0,
                                    .row = self.position.row + 0,
                                },
                                .loc_in_shape = loc0,
                            }, 
                            BlockPart{
                                .grid_position = GridPosition {
                                    .col = self.position.col + 1,
                                    .row = self.position.row + 0,
                                },
                                .loc_in_shape = loc1,
                            }, 
                            BlockPart{
                                .grid_position = GridPosition {
                                    .col = self.position.col + 2,
                                    .row = self.position.row + 0,
                                },
                                .loc_in_shape = loc2,
                            }, 
                            BlockPart{
                                .grid_position = GridPosition {
                                    .col = self.position.col + 2,
                                    .row = self.position.row + 1,
                                },
                                .loc_in_shape = loc3,
                            }, 
                        };
                    },
                    2 => {
                        const loc0 = @intFromEnum(LocationInShape.left) | @intFromEnum(LocationInShape.bottom)
                            | @intFromEnum(LocationInShape.right);
                        const loc1 = @intFromEnum(LocationInShape.left) | @intFromEnum(LocationInShape.right);
                        const loc2 = @intFromEnum(LocationInShape.right) | @intFromEnum(LocationInShape.top);
                        const loc3 = @intFromEnum(LocationInShape.top) | @intFromEnum(LocationInShape.right)
                            | @intFromEnum(LocationInShape.bottom);

                        return [4]BlockPart {
                            BlockPart{
                                .grid_position = GridPosition{
                                    .col = self.position.col + 0,
                                    .row = self.position.row + 2,
                                },
                                .loc_in_shape = loc0,
                            }, 
                            BlockPart{
                                .grid_position = GridPosition {
                                    .col = self.position.col + 0,
                                    .row = self.position.row + 1,
                                },
                                .loc_in_shape = loc1,
                            }, 
                            BlockPart{
                                .grid_position = GridPosition {
                                    .col = self.position.col + 0,
                                    .row = self.position.row + 0,
                                },
                                .loc_in_shape = loc2,
                            }, 
                            BlockPart{
                                .grid_position = GridPosition {
                                    .col = self.position.col + 1,
                                    .row = self.position.row + 0,
                                },
                                .loc_in_shape = loc3,
                            }, 
                        };
                    },
                    3 => {
                        const loc0 = @intFromEnum(LocationInShape.left) | @intFromEnum(LocationInShape.top)
                            | @intFromEnum(LocationInShape.right);
                        const loc1 = @intFromEnum(LocationInShape.left) | @intFromEnum(LocationInShape.bottom);
                        const loc2 = @intFromEnum(LocationInShape.top) | @intFromEnum(LocationInShape.bottom);
                        const loc3 = @intFromEnum(LocationInShape.right) | @intFromEnum(LocationInShape.bottom)
                            | @intFromEnum(LocationInShape.top);

                        return [4]BlockPart {
                            BlockPart{
                                .grid_position = GridPosition{
                                    .col = self.position.col + 0,
                                    .row = self.position.row + 0,
                                },
                                .loc_in_shape = loc0,
                            }, 
                            BlockPart{
                                .grid_position = GridPosition {
                                    .col = self.position.col + 0,
                                    .row = self.position.row + 1,
                                },
                                .loc_in_shape = loc1,
                            }, 
                            BlockPart{
                                .grid_position = GridPosition {
                                    .col = self.position.col + 1,
                                    .row = self.position.row + 1,
                                },
                                .loc_in_shape = loc2,
                            }, 
                            BlockPart{
                                .grid_position = GridPosition {
                                    .col = self.position.col + 2,
                                    .row = self.position.row + 1,
                                },
                                .loc_in_shape = loc3,
                            }, 
                        };
                    },
                }
            },
            BlockShape.T => {
                //                
                // ___  |         |     
                //  |   |-  _|_  -| 
                //      |         |

                switch (self.n_rotations) {
                    0 => {
                       const loc0 = @intFromEnum(LocationInShape.left) | @intFromEnum(LocationInShape.top)
                            | @intFromEnum(LocationInShape.bottom);
                        const loc1 = @intFromEnum(LocationInShape.top);
                        const loc2 = @intFromEnum(LocationInShape.right) | @intFromEnum(LocationInShape.top)
                            | @intFromEnum(LocationInShape.bottom);
                        const loc3 = @intFromEnum(LocationInShape.left) | @intFromEnum(LocationInShape.bottom)
                            | @intFromEnum(LocationInShape.right);

                        return [4]BlockPart {
                            BlockPart{
                                .grid_position = GridPosition{
                                    .col = self.position.col + 0,
                                    .row = self.position.row + 0,
                                },
                                .loc_in_shape = loc0,
                            }, 
                            BlockPart{
                                .grid_position = GridPosition {
                                    .col = self.position.col + 1,
                                    .row = self.position.row + 0,
                                },
                                .loc_in_shape = loc1,
                            }, 
                            BlockPart{
                                .grid_position = GridPosition {
                                    .col = self.position.col + 2,
                                    .row = self.position.row + 0,
                                },
                                .loc_in_shape = loc2,
                            }, 
                            BlockPart{
                                .grid_position = GridPosition {
                                    .col = self.position.col + 1,
                                    .row = self.position.row + 1,
                                },
                                .loc_in_shape = loc3,
                            }, 
                        };
                    },
                    1 => {
                       const loc0 = @intFromEnum(LocationInShape.left) | @intFromEnum(LocationInShape.top)
                            | @intFromEnum(LocationInShape.right);
                        const loc1 = @intFromEnum(LocationInShape.left);
                        const loc2 = @intFromEnum(LocationInShape.right) | @intFromEnum(LocationInShape.bottom)
                            | @intFromEnum(LocationInShape.left);
                        const loc3 = @intFromEnum(LocationInShape.top) | @intFromEnum(LocationInShape.right)
                            | @intFromEnum(LocationInShape.bottom);

                        return [4]BlockPart {
                            BlockPart{
                                .grid_position = GridPosition{
                                    .col = self.position.col + 0,
                                    .row = self.position.row + 0,
                                },
                                .loc_in_shape = loc0,
                            }, 
                            BlockPart{
                                .grid_position = GridPosition {
                                    .col = self.position.col + 0,
                                    .row = self.position.row + 1,
                                },
                                .loc_in_shape = loc1,
                            }, 
                            BlockPart{
                                .grid_position = GridPosition {
                                    .col = self.position.col + 0,
                                    .row = self.position.row + 2,
                                },
                                .loc_in_shape = loc2,
                            }, 
                            BlockPart{
                                .grid_position = GridPosition {
                                    .col = self.position.col + 1,
                                    .row = self.position.row + 1,
                                },
                                .loc_in_shape = loc3,
                            }, 
                        };
                    },
                    2 => {
                       const loc0 = @intFromEnum(LocationInShape.left) | @intFromEnum(LocationInShape.top)
                            | @intFromEnum(LocationInShape.bottom);
                        const loc1 = @intFromEnum(LocationInShape.bottom);
                        const loc2 = @intFromEnum(LocationInShape.right) | @intFromEnum(LocationInShape.top)
                            | @intFromEnum(LocationInShape.bottom);
                        const loc3 = @intFromEnum(LocationInShape.left) | @intFromEnum(LocationInShape.top)
                            | @intFromEnum(LocationInShape.right);

                        return [4]BlockPart {
                            BlockPart{
                                .grid_position = GridPosition{
                                    .col = self.position.col + 0,
                                    .row = self.position.row + 1,
                                },
                                .loc_in_shape = loc0,
                            }, 
                            BlockPart{
                                .grid_position = GridPosition {
                                    .col = self.position.col + 1,
                                    .row = self.position.row + 1,
                                },
                                .loc_in_shape = loc1,
                            }, 
                            BlockPart{
                                .grid_position = GridPosition {
                                    .col = self.position.col + 2,
                                    .row = self.position.row + 1,
                                },
                                .loc_in_shape = loc2,
                            }, 
                            BlockPart{
                                .grid_position = GridPosition {
                                    .col = self.position.col + 1,
                                    .row = self.position.row + 0,
                                },
                                .loc_in_shape = loc3,
                            }, 
                        };
                    },
                    3 => {
                       const loc0 = @intFromEnum(LocationInShape.left) | @intFromEnum(LocationInShape.top)
                            | @intFromEnum(LocationInShape.right);
                        const loc1 = @intFromEnum(LocationInShape.right);
                        const loc2 = @intFromEnum(LocationInShape.right) | @intFromEnum(LocationInShape.left)
                            | @intFromEnum(LocationInShape.bottom);
                        const loc3 = @intFromEnum(LocationInShape.left) | @intFromEnum(LocationInShape.bottom)
                            | @intFromEnum(LocationInShape.top);

                        return [4]BlockPart {
                            BlockPart{
                                .grid_position = GridPosition{
                                    .col = self.position.col + 1,
                                    .row = self.position.row + 0,
                                },
                                .loc_in_shape = loc0,
                            }, 
                            BlockPart{
                                .grid_position = GridPosition {
                                    .col = self.position.col + 1,
                                    .row = self.position.row + 1,
                                },
                                .loc_in_shape = loc1,
                            }, 
                            BlockPart{
                                .grid_position = GridPosition {
                                    .col = self.position.col + 1,
                                    .row = self.position.row + 2,
                                },
                                .loc_in_shape = loc2,
                            }, 
                            BlockPart{
                                .grid_position = GridPosition {
                                    .col = self.position.col + 0,
                                    .row = self.position.row + 1,
                                },
                                .loc_in_shape = loc3,
                            }, 
                        };
                    },
                }
            },
        }
    }
};


pub fn main() !void {
    try initGame();
    defer deinitGame();

    while (!rl.WindowShouldClose()) {
        update();
    }
}

fn initGame() !void {
    const c_time = @cImport(@cInclude("time.h"));
    rl.SetRandomSeed(@intCast(c_time.time(null)));

    main_allocator = std.heap.page_allocator;

    const grid_position = Vector2{
        .x = 0,
        .y = @as(f32, @floatFromInt(gameConfig.getWindowHeight())) / 9,
    };

    const rows = 16;
    const cols = 10;

    gameConfig.cell_size = @divFloor((gameConfig.getWindowHeight() - @as(i32, @intFromFloat(grid_position.y))), rows);

    gameState = GameState{
        .grid = try Grid.new(&main_allocator, rows, cols, grid_position),
        .next_block_shape = @enumFromInt(rl.GetRandomValue(0, @typeInfo(BlockShape).Enum.fields.len - 1)),
    };

    rl.InitWindow(gameConfig.getWindowWidth(), gameConfig.getWindowHeight(), gameConfig.window_name);
    rl.SetTargetFPS(gameConfig.targetFPS); 
}

fn deinitGame() void {
    rl.CloseWindow();
    gameState.grid.destroy();
}

fn update() void {
    updateLogic();
    drawFrame();
}

fn updateLogic() void {
    const dt = rl.GetFrameTime();
    gameState.time_to_tick -= dt;

    if (rl.IsKeyPressed(rl.KEY_DOWN)) {
        gameState.original_tick_time = gameState.tick_time;
        gameState.tick_time /= 2;
    }

    if (rl.IsKeyReleased(rl.KEY_DOWN)) {
        gameState.tick_time = gameState.original_tick_time;
    }

    if (gameState.active_block) |*b| {
        if (rl.IsKeyPressed(rl.KEY_LEFT) and gameState.grid.blockCanMove(b, Direction.left)) {
            b.move(Direction.left);
        } 

        if (rl.IsKeyPressed(rl.KEY_RIGHT) and gameState.grid.blockCanMove(b, Direction.right)) {
            b.move(Direction.right);
        } 

        if (rl.IsKeyPressed(rl.KEY_SPACE)) {
            gameState.grid.rotateBlockIfPossible(b);
        }

        if (gameState.time_to_tick <= 0) {
            gameState.resetTicker();
            if (gameState.grid.blockCanMove(b, Direction.down)) {
                b.move(Direction.down);
                gameState.grid.tryFillSingleHangingRow();
            } else {
                const cells = b.getAllCells();
                gameState.grid.fillCells(&cells);
                gameState.active_block = null;
            }
        }
    } else {
        gameState.createBlock();
    }
}

fn drawFrame() void {
    rl.BeginDrawing();
    defer rl.EndDrawing();
    
    rl.ClearBackground(gameConfig.background_color);
    rl.DrawFPS(gameConfig.getWindowWidth() - 90, 30);

    gameState.draw();
}


