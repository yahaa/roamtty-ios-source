/// Reed-Solomon erasure code over GF(2^8) (polynomial 0x11d) with a Cauchy matrix, the same as the
/// plugin's `fec.rs`: k data shards and m parity shards, any k of them rebuild the data.
/// Port of Android `desktop-core/Fec.kt` (roamtty #218).
public enum Fec {
    public static let maxShards = 255

    private static let tables: (exp: [Int], log: [Int]) = {
        var exp = [Int](repeating: 0, count: 512)
        var log = [Int](repeating: 0, count: 256)
        var x = 1
        for i in 0..<255 {
            exp[i] = x
            log[x] = i
            x <<= 1
            if x & 0x100 != 0 { x ^= 0x11d }
        }
        for i in 255..<512 { exp[i] = exp[i - 255] }
        return (exp, log)
    }()
    private static let exp = tables.exp
    private static let log = tables.log

    @inline(__always) public static func mul(_ a: Int, _ b: Int) -> Int { a == 0 || b == 0 ? 0 : exp[log[a] + log[b]] }
    public static func inv(_ a: Int) -> Int { precondition(a != 0); return exp[255 - log[a]] }

    /// C[j][i] = 1 / (x_j + y_i) with y_i = i, x_j = k + j.
    private static func cauchy(_ k: Int, _ j: Int, _ i: Int) -> Int { inv((k + j) ^ i) }

    /// Row `c` of the multiplication table, for the inner loops.
    private static func row(_ c: Int) -> [UInt8] { (0..<256).map { UInt8(mul(c, $0)) } }

    public static func encode(_ data: [[UInt8]], m: Int) -> [[UInt8]] {
        let k = data.count
        precondition(k > 0 && k + m <= maxShards)
        let len = data[0].count
        return (0..<m).map { j in
            var p = [UInt8](repeating: 0, count: len)
            for (i, d) in data.enumerated() {
                let t = row(cauchy(k, j, i))
                for n in 0..<len { p[n] ^= t[Int(d[n])] }
            }
            return p
        }
    }

    /// The k data shards from any k of `shards` (data first, then parity; nil = lost), or nil with fewer.
    public static func decode(_ shards: [[UInt8]?], k: Int) -> [[UInt8]]? {
        let present = Array(shards.indices.filter { shards[$0] != nil }.prefix(k))
        if present.count < k { return nil }
        if (0..<k).allSatisfy({ shards[$0] != nil }) { return (0..<k).map { shards[$0]! } }
        let len = shards[present[0]]!.count
        var a: [[Int]] = (0..<k).map { r in
            let s = present[r]
            return (0..<k).map { i in s < k ? (s == i ? 1 : 0) : cauchy(k, s - k, i) }
        }
        var b: [[Int]] = (0..<k).map { r in (0..<k).map { $0 == r ? 1 : 0 } }
        for col in 0..<k {
            guard let pivot = (col..<k).first(where: { a[$0][col] != 0 }) else { return nil }
            a.swapAt(col, pivot)
            b.swapAt(col, pivot)
            let f = inv(a[col][col])
            for c in 0..<k { a[col][c] = mul(a[col][c], f); b[col][c] = mul(b[col][c], f) }
            for r in 0..<k where r != col && a[r][col] != 0 {
                let g = a[r][col]
                for c in 0..<k { a[r][c] ^= mul(g, a[col][c]); b[r][c] ^= mul(g, b[col][c]) }
            }
        }
        return (0..<k).map { i in
            var out = [UInt8](repeating: 0, count: len)
            for (r, s) in present.enumerated() {
                let c = b[i][r]
                if c != 0 {
                    let src = shards[s]!, t = row(c)
                    for n in 0..<len { out[n] ^= t[Int(src[n])] }
                }
            }
            return out
        }
    }
}
