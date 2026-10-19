//! CommonCrypto externs (libSystem; nothing to link).
//! Values from CommonCrypto/CommonKeyDerivation.h and CommonCryptor.h.

pub const kCCPBKDF2: u32 = 2;
pub const kCCPRFHmacAlgSHA1: u32 = 1;
pub const kCCPRFHmacAlgSHA256: u32 = 3;

pub const kCCSuccess: i32 = 0;
pub const kCCEncrypt: u32 = 0;
pub const kCCDecrypt: u32 = 1;
/// AES of any key size: the key's length (16, 24, 32) picks it.
pub const kCCAlgorithmAES128: u32 = 0;
pub const kCCAlgorithm3DES: u32 = 2;
pub const kCCOptionPKCS7Padding: u32 = 1;
pub const kCCBlockSizeAES128: usize = 16;
pub const kCCBlockSize3DES: usize = 8;

pub extern "c" fn CCCrypt(
    op: u32,
    alg: u32,
    options: u32,
    key: [*]const u8,
    key_len: usize,
    iv: ?[*]const u8,
    data_in: [*]const u8,
    data_in_len: usize,
    data_out: [*]u8,
    data_out_avail: usize,
    data_out_moved: *usize,
) i32;

pub extern "c" fn CCKeyDerivationPBKDF(
    algorithm: u32,
    password: [*]const u8,
    password_len: usize,
    salt: [*]const u8,
    salt_len: usize,
    prf: u32,
    rounds: c_uint,
    derived: [*]u8,
    derived_len: usize,
) c_int;
