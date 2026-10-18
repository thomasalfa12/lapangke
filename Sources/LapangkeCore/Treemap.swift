import CoreGraphics

/// Tata letak treemap "squarified" (Bruls, Huizing & van Wijk): kotak sebanding ukuran,
/// sedekat mungkin ke persegi supaya mudah dibaca dan diarahkan kursor.
public enum Treemap {
    /// `values` harus ≥ 0; hasil berurutan sama dengan input. Nilai 0 mendapat kotak kosong.
    public static func squarify(_ values: [Double], in rect: CGRect) -> [CGRect] {
        var result = Array(repeating: CGRect.zero, count: values.count)
        let total = values.reduce(0, +)
        guard total > 0, rect.width > 0, rect.height > 0 else { return result }
        let scale = Double(rect.width * rect.height) / total
        // Urutkan besar → kecil, simpan indeks asal.
        var remaining = values.enumerated()
            .filter { $0.element > 0 }
            .map { (index: $0.offset, area: $0.element * scale) }
            .sorted { $0.area > $1.area }
        var free = rect

        func worst(_ row: [(index: Int, area: Double)], side: Double) -> Double {
            let sum = row.reduce(0) { $0 + $1.area }
            guard let largest = row.first?.area, let smallest = row.last?.area, sum > 0, smallest > 0 else { return .infinity }
            let sideSquared = side * side
            return max(sideSquared * largest / (sum * sum), (sum * sum) / (sideSquared * smallest))
        }

        while !remaining.isEmpty {
            let side = Double(min(free.width, free.height))
            var row = [remaining[0]]
            var next = 1
            while next < remaining.count {
                let candidate = row + [remaining[next]]
                if worst(candidate, side: side) <= worst(row, side: side) {
                    row = candidate
                    next += 1
                } else {
                    break
                }
            }
            let rowArea = row.reduce(0) { $0 + $1.area }
            if free.width >= free.height {
                // Kolom di kiri.
                let width = CGFloat(rowArea / Double(free.height))
                var y = free.minY
                for entry in row {
                    let height = CGFloat(entry.area / Double(width))
                    result[entry.index] = CGRect(x: free.minX, y: y, width: width, height: height)
                    y += height
                }
                free = CGRect(x: free.minX + width, y: free.minY, width: max(0, free.width - width), height: free.height)
            } else {
                // Baris di atas.
                let height = CGFloat(rowArea / Double(free.width))
                var x = free.minX
                for entry in row {
                    let width = CGFloat(entry.area / Double(height))
                    result[entry.index] = CGRect(x: x, y: free.minY, width: width, height: height)
                    x += width
                }
                free = CGRect(x: free.minX, y: free.minY + height, width: free.width, height: max(0, free.height - height))
            }
            remaining.removeFirst(row.count)
        }
        return result
    }
}
