import SpriteKit

struct Cat {
    static let ground: UInt32 = 1
    static let player: UInt32 = 2
    static let spike: UInt32 = 4
    static let finish: UInt32 = 8
    static let crate: UInt32 = 16
}

/// Semi-transparent copy of the other player, driven by network packets.
final class Ghost {
    private var nodes: [SKNode] = []
    private let chassis = SKSpriteNode(color: .systemPurple, size: CGSize(width: 70, height: 12))
    private let torso = SKSpriteNode(color: .systemOrange, size: CGSize(width: 14, height: 36))
    private let w1 = SKShapeNode(circleOfRadius: 18)
    private let w2 = SKShapeNode(circleOfRadius: 18)
    private let head = SKShapeNode(circleOfRadius: 10)
    private var shown = false

    init(scene: SKScene) {
        nodes = [chassis, torso, w1, w2, head]
        for w in [w1, w2] { w.fillColor = .gray; w.strokeColor = .white }
        head.fillColor = .systemTeal
        head.strokeColor = .white
        for n in nodes { n.alpha = 0; n.zPosition = 5; scene.addChild(n) }
    }

    func apply(_ s: PlayerState) {
        if !shown { shown = true; nodes.forEach { $0.alpha = 0.55 } }
        place(chassis, s.cx, s.cy, s.ca)
        place(torso, s.tx, s.ty, s.ta)
        place(w1, s.w1x, s.w1y, nil)
        place(w2, s.w2x, s.w2y, nil)
        place(head, s.hx, s.hy, nil)
    }

    private func place(_ n: SKNode, _ x: Float, _ y: Float, _ a: Float?) {
        let p = CGPoint(x: CGFloat(x), y: CGFloat(y))
        if hypot(n.position.x - p.x, n.position.y - p.y) > 300 {
            n.position = p
        } else {
            n.position.x += (p.x - n.position.x) * 0.4
            n.position.y += (p.y - n.position.y) * 0.4
        }
        if let a = a { n.zRotation = CGFloat(a) }
    }
}

final class GameScene: SKScene, SKPhysicsContactDelegate {
    enum Status: Int { case riding = 0, dead = 1, finished = 2 }

    static let finishX: CGFloat = 6900
    static let gaps: [(CGFloat, CGFloat)] = [(2600, 2800), (4400, 4650)]

    var lan: LAN?
    private var status: Status = .riding

    private let cam = SKCameraNode()
    private var chassis: SKSpriteNode!
    private var torso: SKSpriteNode!
    private var head: SKShapeNode!
    private var wheels: [SKShapeNode] = []
    private var riderJoints: [SKPhysicsJoint] = []
    private var playerNodes: [SKNode] = []

    private var ghost: Ghost?
    private var remote: PlayerState?
    private var raceOver = false

    private var buttons: [String: SKShapeNode] = [:]
    private var held = Set<String>()
    private var touchMap: [UITouch: String] = [:]

    private var checkpointX: CGFloat = 100
    private var lastSend: TimeInterval = 0
    private var lastUpdate: TimeInterval = 0

    private let banner = SKLabelNode(fontNamed: "AvenirNext-Heavy")
    private let hud = SKLabelNode(fontNamed: "AvenirNext-Bold")

    // MARK: Level

    /// Deterministic terrain so both players race on identical ground.
    static func groundY(_ x: CGFloat) -> CGFloat {
        var y = 90 + 45 * sin(x / 260) + 18 * sin(x / 95)
        if x > 2420 && x <= 2600 { y += (x - 2420) * 0.3 }   // launch ramp
        if x > 4220 && x <= 4400 { y += (x - 4220) * 0.3 }   // launch ramp
        return y
    }

    override func didMove(to view: SKView) {
        backgroundColor = SKColor(red: 0.53, green: 0.81, blue: 0.92, alpha: 1)
        physicsWorld.gravity = CGVector(dx: 0, dy: -11)
        physicsWorld.contactDelegate = self
        view.isMultipleTouchEnabled = true

        camera = cam
        addChild(cam)

        buildLevel()
        buildHUD()
        spawn()

        if let lan = lan, lan.connected {
            ghost = Ghost(scene: self)
            lan.onPacket = { [weak self] p in self?.handle(p) }
        }
    }

    private func buildLevel() {
        let segments: [(CGFloat, CGFloat)] = [(-300, 2600), (2800, 4400), (4650, 7200)]
        for (a, b) in segments {
            let line = CGMutablePath()
            var x = a
            line.move(to: CGPoint(x: x, y: Self.groundY(x)))
            while x < b {
                x = min(x + 20, b)
                line.addLine(to: CGPoint(x: x, y: Self.groundY(x)))
            }
            let fill = line.mutableCopy()!
            fill.addLine(to: CGPoint(x: b, y: -500))
            fill.addLine(to: CGPoint(x: a, y: -500))
            fill.closeSubpath()

            let shape = SKShapeNode(path: fill)
            shape.fillColor = SKColor(red: 0.45, green: 0.30, blue: 0.15, alpha: 1)
            shape.strokeColor = SKColor(red: 0.2, green: 0.6, blue: 0.2, alpha: 1)
            shape.lineWidth = 5
            let body = SKPhysicsBody(edgeChainFrom: line)
            body.categoryBitMask = Cat.ground
            body.friction = 1.0
            shape.physicsBody = body
            addChild(shape)
        }

        // Spikes
        for sx in [900, 1500, 2150, 3300, 3900, 5200, 5900] as [CGFloat] {
            for i in 0..<3 {
                let x = sx + CGFloat(i) * 22
                let p = CGMutablePath()
                p.move(to: CGPoint(x: -11, y: 0))
                p.addLine(to: CGPoint(x: 0, y: 30))
                p.addLine(to: CGPoint(x: 11, y: 0))
                p.closeSubpath()
                let s = SKShapeNode(path: p)
                s.fillColor = .lightGray
                s.strokeColor = .white
                s.position = CGPoint(x: x, y: Self.groundY(x) - 3)
                let b = SKPhysicsBody(polygonFrom: p)
                b.isDynamic = false
                b.categoryBitMask = Cat.spike
                b.collisionBitMask = 0
                b.contactTestBitMask = Cat.player
                s.physicsBody = b
                addChild(s)
            }
        }

        // Crates
        for cx in [700, 1200, 1800, 3100, 3600, 5100, 5600] as [CGFloat] {
            let c = SKSpriteNode(color: .orange, size: CGSize(width: 40, height: 40))
            c.position = CGPoint(x: cx, y: Self.groundY(cx) + 25)
            let b = SKPhysicsBody(rectangleOf: c.size)
            b.density = 0.4
            b.friction = 0.8
            b.categoryBitMask = Cat.crate
            b.collisionBitMask = Cat.ground | Cat.crate | Cat.player
            c.physicsBody = b
            addChild(c)
        }

        // Finish line
        let f = SKSpriteNode(color: .white, size: CGSize(width: 10, height: 400))
        f.position = CGPoint(x: Self.finishX, y: Self.groundY(Self.finishX) + 200)
        let fb = SKPhysicsBody(rectangleOf: f.size)
        fb.isDynamic = false
        fb.categoryBitMask = Cat.finish
        fb.collisionBitMask = 0
        fb.contactTestBitMask = Cat.player
        f.physicsBody = fb
        addChild(f)
        let fl = SKLabelNode(text: "FINISH 🏁")
        fl.fontName = "AvenirNext-Heavy"
        fl.fontSize = 36
        fl.fontColor = .black
        fl.position = CGPoint(x: Self.finishX, y: Self.groundY(Self.finishX) + 120)
        addChild(fl)
    }

    private func buildHUD() {
        cam.zPosition = 100
        hud.fontSize = 22
        hud.horizontalAlignmentMode = .left
        hud.fontColor = .black
        hud.position = CGPoint(x: -430, y: 170)
        cam.addChild(hud)

        banner.fontSize = 46
        banner.fontColor = .white
        banner.position = CGPoint(x: 0, y: 70)
        cam.addChild(banner)

        addButton("leanL", "↺", CGPoint(x: -380, y: -140))
        addButton("leanR", "↻", CGPoint(x: -280, y: -140))
        addButton("rev", "◀", CGPoint(x: 280, y: -140))
        addButton("gas", "▶", CGPoint(x: 380, y: -140))
    }

    private func addButton(_ name: String, _ title: String, _ pos: CGPoint) {
        let b = SKShapeNode(circleOfRadius: 42)
        b.name = name
        b.position = pos
        b.fillColor = SKColor(white: 1, alpha: 0.2)
        b.strokeColor = .white
        let l = SKLabelNode(text: title)
        l.fontSize = 34
        l.verticalAlignmentMode = .center
        b.addChild(l)
        cam.addChild(b)
        buttons[name] = b
    }

    // MARK: Player

    private func make(_ b: SKPhysicsBody, density: CGFloat, friction: CGFloat = 0.6) -> SKPhysicsBody {
        b.density = density
        b.friction = friction
        b.restitution = 0.1
        b.categoryBitMask = Cat.player
        b.collisionBitMask = Cat.ground | Cat.crate
        b.contactTestBitMask = 0
        return b
    }

    private func add(_ n: SKNode) {
        addChild(n)
        playerNodes.append(n)
    }

    private func spawn() {
        removeAction(forKey: "respawn")
        playerNodes.forEach { $0.removeFromParent() }
        playerNodes = []
        wheels = []
        riderJoints = []
        status = .riding

        let x = checkpointX
        let y = Self.groundY(x) + 50

        chassis = SKSpriteNode(color: .systemBlue, size: CGSize(width: 70, height: 12))
        chassis.position = CGPoint(x: x, y: y)
        chassis.zPosition = 10
        chassis.physicsBody = make(SKPhysicsBody(rectangleOf: chassis.size), density: 2.0)
        add(chassis)

        var wheelJoints: [SKPhysicsJoint] = []
        for dx in [CGFloat(-30), CGFloat(30)] {
            let w = SKShapeNode(circleOfRadius: 18)
            w.fillColor = .darkGray
            w.strokeColor = .white
            let spoke = SKShapeNode(rectOf: CGSize(width: 34, height: 3))
            spoke.fillColor = .white
            spoke.strokeColor = .clear
            w.addChild(spoke)
            w.position = CGPoint(x: x + dx, y: y - 8)
            w.zPosition = 10
            w.physicsBody = make(SKPhysicsBody(circleOfRadius: 18), density: 1.0, friction: 1.2)
            add(w)
            wheels.append(w)
            wheelJoints.append(SKPhysicsJointPin.joint(withBodyA: chassis.physicsBody!,
                                                       bodyB: w.physicsBody!,
                                                       anchor: w.position))
        }

        torso = SKSpriteNode(color: .systemRed, size: CGSize(width: 14, height: 36))
        torso.position = CGPoint(x: x, y: y + 24)
        torso.zPosition = 11
        torso.physicsBody = make(SKPhysicsBody(rectangleOf: torso.size), density: 0.6)
        add(torso)

        head = SKShapeNode(circleOfRadius: 10)
        head.name = "head"
        head.fillColor = .systemYellow
        head.strokeColor = .black
        head.position = CGPoint(x: x, y: y + 50)
        head.zPosition = 12
        let hb = make(SKPhysicsBody(circleOfRadius: 10), density: 0.4)
        hb.contactTestBitMask = Cat.ground          // head hitting dirt = ouch
        head.physicsBody = hb
        add(head)

        wheelJoints.forEach { physicsWorld.add($0) }

        let seat = SKPhysicsJointPin.joint(withBodyA: chassis.physicsBody!,
                                           bodyB: torso.physicsBody!,
                                           anchor: CGPoint(x: x, y: y + 6))
        seat.shouldEnableLimits = true
        seat.lowerAngleLimit = -0.7
        seat.upperAngleLimit = 0.7
        physicsWorld.add(seat)
        riderJoints = [seat]

        let neck = SKPhysicsJointPin.joint(withBodyA: torso.physicsBody!,
                                           bodyB: head.physicsBody!,
                                           anchor: CGPoint(x: x, y: y + 42))
        neck.shouldEnableLimits = true
        neck.lowerAngleLimit = -1.0
        neck.upperAngleLimit = 1.0
        physicsWorld.add(neck)

        cam.position = chassis.position
    }

    private func kill() {
        guard status == .riding else { return }
        status = .dead
        riderJoints.forEach { physicsWorld.remove($0) }   // rider flies off the bike
        riderJoints = []
        showBanner("💥 Ouch!")
        run(.sequence([.wait(forDuration: 1.8),
                       .run { [weak self] in self?.banner.text = ""; self?.spawn() }]),
            withKey: "respawn")
    }

    private func win() {
        guard status == .riding else { return }
        status = .finished
        if !raceOver {
            raceOver = true
            showBanner("You win! 🏆")
            lan?.send(Packet(kind: 1, state: nil), reliable: true)
            scheduleReset()
        }
    }

    private func showBanner(_ s: String) { banner.text = s }

    private func scheduleReset() {
        run(.sequence([.wait(forDuration: 4),
                       .run { [weak self] in self?.resetRace() }]),
            withKey: "reset")
    }

    private func resetRace() {
        raceOver = false
        checkpointX = 100
        banner.text = ""
        spawn()
    }

    // MARK: Networking

    private func handle(_ p: Packet) {
        if p.kind == 0 {
            remote = p.state
        } else if p.kind == 1, !raceOver, status != .finished {
            raceOver = true
            showBanner("Opponent wins! 🏁")
            scheduleReset()
        }
    }

    private func snapshot() -> PlayerState {
        func f(_ v: CGFloat) -> Float { Float(v) }
        return PlayerState(cx: f(chassis.position.x), cy: f(chassis.position.y), ca: f(chassis.zRotation),
                           w1x: f(wheels[0].position.x), w1y: f(wheels[0].position.y),
                           w2x: f(wheels[1].position.x), w2y: f(wheels[1].position.y),
                           tx: f(torso.position.x), ty: f(torso.position.y), ta: f(torso.zRotation),
                           hx: f(head.position.x), hy: f(head.position.y),
                           status: status.rawValue)
    }

    // MARK: Loop

    override func update(_ t: TimeInterval) {
        let dt = lastUpdate == 0 ? 1.0 / 60 : min(t - lastUpdate, 1.0 / 20)
        lastUpdate = t
        let d = CGFloat(dt)

        if status == .riding {
            let gas = held.contains("gas"), rev = held.contains("rev")
            for w in wheels {
                guard let pb = w.physicsBody else { continue }
                var av = pb.angularVelocity
                if gas { av = max(av - 45 * d, -28) }      // clockwise = forward
                if rev { av = min(av + 45 * d, 28) }
                pb.angularVelocity = av
            }
            if let cb = chassis.physicsBody {
                if held.contains("leanL") { cb.angularVelocity += 14 * d }
                if held.contains("leanR") { cb.angularVelocity -= 14 * d }
            }
            checkpointX = max(checkpointX, floor(min(chassis.position.x, Self.finishX - 1) / 1000) * 1000)
            if chassis.position.y < -250 { kill() }
        }

        let target = CGPoint(x: chassis.position.x + 100, y: chassis.position.y + 30)
        cam.position.x += (target.x - cam.position.x) * 0.15
        cam.position.y += (target.y - cam.position.y) * 0.15

        hud.text = "\(max(0, Int(chassis.position.x / 50))) / \(Int(Self.finishX / 50)) m"

        if let lan = lan, lan.connected {
            if t - lastSend > 0.05 {
                lastSend = t
                lan.send(Packet(kind: 0, state: snapshot()), reliable: false)
            }
            if let r = remote { ghost?.apply(r) }
        }
    }

    func didBegin(_ c: SKPhysicsContact) {
        guard status == .riding else { return }
        let m = c.bodyA.categoryBitMask | c.bodyB.categoryBitMask
        if m & Cat.player == 0 { return }
        if m & Cat.spike != 0 {
            kill()
        } else if m & Cat.finish != 0 {
            win()
        } else if m & Cat.ground != 0 {
            if c.bodyA.node?.name == "head" || c.bodyB.node?.name == "head" { kill() }
        }
    }

    // MARK: Touch

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) { track(touches) }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) { track(touches) }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { release(touches) }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { release(touches) }

    private func track(_ touches: Set<UITouch>) {
        for t in touches {
            let p = t.location(in: cam)
            touchMap[t] = cam.nodes(at: p).compactMap { $0.name }.first { buttons[$0] != nil }
        }
        refreshHeld()
    }

    private func release(_ touches: Set<UITouch>) {
        for t in touches { touchMap[t] = nil }
        refreshHeld()
    }

    private func refreshHeld() {
        held = Set(touchMap.values.compactMap { $0 })
        for (name, b) in buttons {
            b.fillColor = SKColor(white: 1, alpha: held.contains(name) ? 0.6 : 0.2)
        }
    }
}
