const HEADER =
    \\==================================================================================
    \\
    \\db       .d88b.  d888888b db   db  .d88b.  d8888b.  .d8b.  d8888b. d88888b d8888b.
    \\88      .8P  Y8. `~~88~~' 88   88 .8P  Y8. 88  `8D d8' `8b 88  `8D 88'     88  `8D
    \\88      88    88    88    88ooo88 88    88 88oodD' 88ooo88 88oodD' 88ooooo 88oobY'
    \\88      88    88    88    88~~~88 88    88 88~~~   88~~~88 88~~~   88~~~~~ 88`8b
    \\88booo. `8b  d8'    88    88   88 `8b  d8' 88      88   88 88      88.     88 `88.
    \\Y88888P  `Y88P'     YP    YP   YP  `Y88P'  88      YP   YP 88      Y88888P 88   YD
    \\
;

const VERSION_PREFIX = " Version: ";
const VERSION_SUFFIX = " ";
const TAIL = "\n";

const std = @import("std");

const VERSION = @import("build.zig.zon").version;
pub const ASCII = getAscii();

fn getAscii() []const u8 {
    var iterator = std.mem.splitSequence(u8, HEADER, "\n");
    const lineLen = iterator.next().?.len;

    const fullVersion = VERSION_PREFIX ++ VERSION ++ VERSION_SUFFIX;
    const fillerLen = @divTrunc(lineLen - fullVersion.len, 2);

    const sep = "=" ** fillerLen;
    return HEADER ++ "\n" ++ sep ++ fullVersion ++ sep ++ "\n" ++ TAIL;
}

fn getAsciiLineLength() comptime_int {
    const iterator = std.mem.splitSequence(u8, HEADER, "\n");
    return iterator.next();
}
