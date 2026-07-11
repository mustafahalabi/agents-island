import SwiftUI

/// The Agents Island mascot: a tiny pixel-art robot rendered from string
/// bitmaps, tinted by agent status. Designs are data — swap the frames
/// to rebrand. Legend: '#' body · 'O' eye · '-' closed eye · '=' mouth ·
/// '+' antenna light · '.' empty.
enum BotSprite {
    static let workA = """
    .....+......
    .....#......
    ..########..
    ..#OO##OO#..
    ..########..
    ..#======#..
    ..########..
    .#.######.#.
    .#..####..#.
    ....#..#....
    ...##..##...
    """

    static let workB = """
    .....#......
    .....#......
    ..########..
    ..#OO##OO#..
    ..########..
    ..#======#..
    ..########..
    .#.######.#.
    .#..####..#.
    ....#..#....
    ..##....##..
    """

    static let awake = """
    .....+......
    .....#......
    ..########..
    ..#OO##OO#..
    ..########..
    ..#======#..
    ..########..
    .#.######.#.
    .#..####..#.
    ....#..#....
    ...##..##...
    """

    static let blink = """
    .....+......
    .....#......
    ..########..
    ..#--##--#..
    ..########..
    ..#======#..
    ..########..
    .#.######.#.
    .#..####..#.
    ....#..#....
    ...##..##...
    """

    static let sleep = """
    ............
    .....#......
    ..########..
    ..#--##--#..
    ..########..
    ..#======#..
    ..########..
    .#.######.#.
    .#..####..#.
    ....#..#....
    ...##..##...
    """

    static func grid(_ sprite: String) -> [[Character]] {
        sprite.split(separator: "\n").map(Array.init)
    }
}

struct PixelBotView: View {
    let status: AgentStatus
    var size: CGFloat = 22

    private static let workFrames = [BotSprite.grid(BotSprite.workA), BotSprite.grid(BotSprite.workB)]
    private static let waitFrames = [BotSprite.grid(BotSprite.awake), BotSprite.grid(BotSprite.awake),
                                     BotSprite.grid(BotSprite.awake), BotSprite.grid(BotSprite.blink)]
    private static let idleFrames = [BotSprite.grid(BotSprite.sleep)]

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.45)) { context in
            let tick = Int(context.date.timeIntervalSinceReferenceDate / 0.45)
            Canvas { canvas, canvasSize in
                let grid = currentGrid(tick: tick)
                let rows = grid.count
                let cols = grid.first?.count ?? 1
                let pixel = min(canvasSize.width / CGFloat(cols), canvasSize.height / CGFloat(rows))
                let xOffset = (canvasSize.width - pixel * CGFloat(cols)) / 2
                let yOffset = (canvasSize.height - pixel * CGFloat(rows)) / 2

                for (y, row) in grid.enumerated() {
                    for (x, char) in row.enumerated() {
                        guard let color = color(for: char) else { continue }
                        let rect = CGRect(
                            x: xOffset + CGFloat(x) * pixel,
                            y: yOffset + CGFloat(y) * pixel,
                            width: pixel + 0.4, height: pixel + 0.4
                        )
                        canvas.fill(Path(rect), with: .color(color))
                    }
                }
            }
        }
        .frame(width: size, height: size)
    }

    private func currentGrid(tick: Int) -> [[Character]] {
        let frames: [[[Character]]]
        switch status {
        case .working: frames = Self.workFrames
        case .waiting: frames = Self.waitFrames
        case .idle: frames = Self.idleFrames
        }
        return frames[tick % frames.count]
    }

    private func color(for char: Character) -> Color? {
        let tint = status.color
        switch char {
        case "#": return tint.opacity(status == .idle ? 0.55 : 0.95)
        case "O": return .white.opacity(0.95)
        case "-": return .black.opacity(0.6)
        case "=": return .black.opacity(0.55)
        case "+": return status == .working ? .white : tint
        default: return nil
        }
    }
}
