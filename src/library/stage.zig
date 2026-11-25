const authoring = @import("../authoring.zig");

pub fn context(body: anytype, value: anytype) authoring.Error!@TypeOf(value) {
    return body.bindingTime(.context, value);
}

pub fn residual(body: anytype, value: anytype) authoring.Error!@TypeOf(value) {
    return body.bindingTime(.residual, value);
}
