/**
 * @description Pure Apex ZIP archive builder — no external dependencies.
 *
 *  Apex constraints addressed:
 *  - No hex literals: constants are decimal
 *  - No unsigned right shift (>>>): not in Apex; use Long right-shift (>>)
 *  - Long arithmetic used throughout CRC to avoid signed Integer overflow
 *  - charAt() returns Integer in Apex — convert via substring(i,i+1)
 *  - List() constructor takes no capacity arg in Apex
 *  - Long cannot be assigned from Integer without explicit cast
 */
public class Zippex {

    // ZIP signature constants (decimal equivalents of the standard hex values)
    // PK\x03\x04  = 0x04034b50 = 67324752
    private static final Integer SIG_LOCAL   = 67324752;
    // PK\x01\x02  = 0x02014b50 = 33639248
    private static final Integer SIG_CENTRAL = 33639248;
    // PK\x05\x06  = 0x06054b50 = 101010256
    private static final Integer SIG_EOCD    = 101010256;

    // CRC-32 polynomial 0xEDB88320 as unsigned Long
    private static final Long CRC_POLY = 3988292384L;
    // 0xFFFFFFFF as unsigned Long
    private static final Long CRC_INIT = 4294967295L;

    private List<Blob>    blobs    = new List<Blob>();
    private List<String>  names    = new List<String>();
    private List<Long>    crcs     = new List<Long>();
    private List<Integer> sizes    = new List<Integer>();
    private List<Integer> offsets  = new List<Integer>();
    private Integer       curOffset = 0;

    public Zippex() {}

    public void addFile(String fileName, Blob data, String comment) {
        Integer sz = data.size();
        Long    cr = crc32(data);
        names.add(fileName);
        blobs.add(data);
        crcs.add(cr);
        sizes.add(sz);
        offsets.add(curOffset);
        curOffset += 30 + fileName.length() + sz;
    }

    public Blob getZipArchive() {
        List<String> localParts = new List<String>();
        for (Integer i = 0; i < names.size(); i++) localParts.add(localEntry(i));
        String h = String.join(localParts, '');

        Integer cdOff = h.length() / 2;
        List<String> cdParts = new List<String>();
        for (Integer i = 0; i < names.size(); i++) cdParts.add(centralEntry(i));
        String cd = String.join(cdParts, '');
        h += cd;
        h += eocd(names.size(), cd.length() / 2, cdOff);

        return EncodingUtil.convertFromHex(h);
    }

    // ── Local file entry ──────────────────────────────────────────────────────

    private String localEntry(Integer i) {
        Integer sz  = sizes[i];
        Long    crc = crcs[i];
        Integer nl  = names[i].length();
        return
            le4i(SIG_LOCAL) + '1400' + '0000' + '0000' + '0000' + '0000' +
            le4L(crc) + le4i(sz) + le4i(sz) + le2(nl) + '0000' +
            blobHex(Blob.valueOf(names[i])) +
            blobHex(blobs[i]);
    }

    // ── Central directory entry ───────────────────────────────────────────────

    private String centralEntry(Integer i) {
        Integer sz  = sizes[i];
        Long    crc = crcs[i];
        Integer nl  = names[i].length();
        Integer off = offsets[i];
        return
            le4i(SIG_CENTRAL) + '1400' + '1400' + '0000' + '0000' +
            '0000' + '0000' +
            le4L(crc) + le4i(sz) + le4i(sz) +
            le2(nl) + '0000' + '0000' + '0000' + '0000' + '00000000' +
            le4i(off) +
            blobHex(Blob.valueOf(names[i]));
    }

    // ── End of central directory record ──────────────────────────────────────

    private String eocd(Integer n, Integer cdSize, Integer cdOff) {
        return
            le4i(SIG_EOCD) + '0000' + '0000' +
            le2(n) + le2(n) +
            le4i(cdSize) + le4i(cdOff) + '0000';
    }

    // ── CRC-32 ────────────────────────────────────────────────────────────────

    private static Long crc32(Blob data) {
        // Build lookup table
        Long[] tbl = new Long[256];
        for (Integer n = 0; n < 256; n++) {
            Long c = (Long) n;
            for (Integer k = 0; k < 8; k++) {
                if (Math.mod(c, 2L) == 1L) {
                    c = CRC_POLY ^ (c >> 1);
                } else {
                    c = c >> 1;
                }
            }
            tbl[n] = c;
        }
        String hexStr = EncodingUtil.convertToHex(data);
        Integer len   = hexStr.length();
        Long    crcVal = CRC_INIT;
        // convertToHex yields lowercase hex. Decode each byte via charAt (which
        // returns the char code with no String allocation) instead of substring
        // + indexOf per byte — the latter is the main CPU cost on large payloads.
        for (Integer i = 0; i < len; i += 2) {
            Integer hi = hexStr.charAt(i);       // '0'-'9' = 48-57, 'a'-'f' = 97-102
            Integer lo = hexStr.charAt(i + 1);
            Integer bv = ((hi <= 57 ? hi - 48 : hi - 87) * 16)
                       +  (lo <= 57 ? lo - 48 : lo - 87);
            Long idx = (crcVal ^ (Long) bv) & 255L;
            crcVal = tbl[idx.intValue()] ^ (crcVal >> 8);
        }
        return crcVal ^ CRC_INIT;
    }

    // ── Little-endian encoding ────────────────────────────────────────────────

    // Integer → 4-byte LE hex
    private static String le4i(Integer v) {
        return le2(v & 65535) + le2((v >> 16) & 65535);
    }

    // Long → 4-byte LE hex (used for CRC which can exceed signed Integer range)
    private static String le4L(Long v) {
        Integer lo = (Integer)(v & 65535L);
        Integer hi = (Integer)((v >> 16) & 65535L);
        return le2(lo) + le2(hi);
    }

    // Integer → 2-byte LE hex
    private static String le2(Integer v) {
        return hb(v & 255) + hb((v >> 8) & 255);
    }

    // Single byte → 2-char hex string
    private static String hb(Integer b) {
        return hexChar(b >> 4) + hexChar(b & 15);
    }

    private static String hexChar(Integer n) {
        return '0123456789abcdef'.substring(n, n + 1);
    }

    // Blob → hex string
    private static String blobHex(Blob b) {
        return EncodingUtil.convertToHex(b);
    }
}
