//! UTF-8 helpers every platform shares.

/// The length of the UTF-8 sequence starting with `b` (1 for a stray byte).
pub fn seqLen(b: u8) usize {
    if (b < 0x80) return 1;
    if (b >> 5 == 0b110) return 2;
    if (b >> 4 == 0b1110) return 3;
    if (b >> 3 == 0b11110) return 4;
    return 1;
}
