import ALifeClient
import Foundation
import Metal
import RealityKit

/// The edges of the lot's box, gently shown, so it feels like the inside of
/// a diorama: along each of its twelve edges (see `HorizonPlan.edges`), the
/// two sides that meet there are shaded softly towards it, as in the inside
/// corner of a real box, and a narrow bevel across the corner catches a
/// little light, pale by day and moonlit at night (`BoxEdgesComponent`).
/// It sits in front of the world painted on the walls, and is only to look
/// at: nothing in it takes taps or casts a shadow.
@MainActor
enum BoxEdges {
    /// How far in front of each side the shading is: in front of the world
    /// on the walls, just over the grass, and just under the clouds.
    nonisolated static func inset(of side: SIMD3<Float>) -> Float {
        if side.y > 0.5 { return 0.012 }
        if side.y < -0.5 { return 0.06 }
        return 0.34
    }

    /// How far out from an edge a side is shaded, in metres: less on the
    /// lot and the bottom of the walls, so it stays a soft line along the
    /// grass.
    nonisolated static func shadeWidth(on side: SIMD3<Float>, along edge: HorizonPlan.Edge) -> Float {
        let isBottom = edge.from.y == 0 && edge.to.y == 0
        if side.y > 0.5 { return 1.6 }
        return isBottom ? 2 : 4.5
    }

    /// How wide the bevel across each corner is, in metres.
    nonisolated static let bevel: Float = 0.07
    /// How much the bevel shows, and its colour in full daylight.
    nonisolated static let bevelOpacity: Float = 0.16
    nonisolated static let bevelColor = SIMD3<Float>(0.96, 0.97, 1)

    static func make() -> ModelEntity {
        var shade = (positions: [SIMD3<Float>](), normals: [SIMD3<Float>](), coordinates: [SIMD2<Float>](), indices: [UInt32]())
        var bevels = (positions: [SIMD3<Float>](), normals: [SIMD3<Float>](), indices: [UInt32]())

        for edge in HorizonPlan.edges {
            let (first, second) = edge.sides
            // Where the two sides' shading meets, in front of the edge, and
            // in from its ends, too, as far as the sides there are.
            let offset = first * inset(of: first) + second * inset(of: second)
            let along = simd_normalize(edge.to - edge.from)
            let from = edge.from + offset + along * inset(of: along)
            let to = edge.to + offset - along * inset(of: -along)

            // On each side, a strip from the edge out across it, along the
            // other side's way in.
            for (side, out) in [(first, second), (second, first)] {
                let width = shadeWidth(on: side, along: edge)
                let start = UInt32(shade.positions.count)
                shade.positions += [from, to, to + out * width, from + out * width]
                shade.normals += Array(repeating: side, count: 4)
                // Darkest at the edge, at 0, fading out to 1.
                shade.coordinates += [[0, 0.5], [0, 0.5], [1, 0.5], [1, 0.5]]
                shade.indices += wound([start, start + 1, start + 2, start + 3], positions: shade.positions, facing: side)
            }

            // The bevel across the corner, facing out of it.
            let facing = simd_normalize(first + second)
            let start = UInt32(bevels.positions.count)
            bevels.positions += [from + second * bevel, to + second * bevel, to + first * bevel, from + first * bevel]
            bevels.normals += Array(repeating: facing, count: 4)
            bevels.indices += wound([start, start + 1, start + 2, start + 3], positions: bevels.positions, facing: facing)
        }

        var shadeMesh = MeshDescriptor(name: "Edge shade")
        shadeMesh.positions = MeshBuffers.Positions(shade.positions)
        shadeMesh.normals = MeshBuffers.Normals(shade.normals)
        shadeMesh.textureCoordinates = MeshBuffers.TextureCoordinates(shade.coordinates)
        shadeMesh.primitives = .triangles(shade.indices)
        shadeMesh.materials = .allFaces(0)
        var bevelMesh = MeshDescriptor(name: "Edge bevels")
        bevelMesh.positions = MeshBuffers.Positions(bevels.positions)
        bevelMesh.normals = MeshBuffers.Normals(bevels.normals)
        bevelMesh.primitives = .triangles(bevels.indices)
        bevelMesh.materials = .allFaces(1)

        let edges = ModelEntity()
        edges.name = "Box edges"
        if let mesh = try? MeshResource.generate(from: [shadeMesh, bevelMesh]) {
            edges.model = ModelComponent(mesh: mesh, materials: [makeShade(), makeBevel(in: .one)])
        }
        edges.components.set(BoxEdgesComponent())
        edges.components.set(DynamicLightShadowComponent(castsShadow: false))
        edges.components.set(ModelSortGroupComponent(group: SkyBox.order, order: 4))
        return edges
    }

    /// Lights the bevels as the world on the walls is lit, in `light`.
    static func light(_ edges: ModelEntity, in light: SIMD3<Float>) {
        guard var materials = edges.model?.materials, materials.count == 2 else { return }
        materials[1] = makeBevel(in: light)
        edges.model?.materials = materials
    }

    /// Black, as see-through as `HorizonPlan.seamShade` says, from the edge
    /// (at the texture's left) out (at its right).
    private static func makeShade() -> UnlitMaterial {
        var material = UnlitMaterial(applyPostProcessToneMap: false)
        material.color = .init(tint: .black)
        // So where two strips overlap at a corner, both shade it.
        material.writesDepth = false
        let sampler = MTLSamplerDescriptor()
        sampler.minFilter = .linear
        sampler.magFilter = .linear
        sampler.sAddressMode = .clampToEdge
        sampler.tAddressMode = .clampToEdge
        let width = 64
        let fade = SkyBox.makeGrey(width: width, height: 1) { column, _ in
            HorizonPlan.seamShade(at: Float(column) / Float(width - 1), width: 1)
        }
        material.blending = .transparent(opacity: .init(scale: fade == nil ? 0 : 1, texture: fade.map { .init($0, sampler: .init(sampler)) }))
        return material
    }

    private static func makeBevel(in light: SIMD3<Float>) -> UnlitMaterial {
        var material = UnlitMaterial(applyPostProcessToneMap: false)
        // A little lighter than the world on the walls at night, so the
        // edges still show in the moonlight.
        material.color = .init(tint: PlatformColor(bevelColor * SkyBox.mix(light, .one, 0.35)))
        material.writesDepth = false
        material.blending = .transparent(opacity: .init(floatLiteral: bevelOpacity))
        return material
    }

    /// The two triangles of a four-cornered face, its corners in order round
    /// its edge, wound to face `facing`.
    private static func wound(_ corners: [UInt32], positions: [SIMD3<Float>], facing: SIMD3<Float>) -> [UInt32] {
        let (a, b, c, d) = (corners[0], corners[1], corners[2], corners[3])
        let cross = simd_cross(positions[Int(b)] - positions[Int(a)], positions[Int(c)] - positions[Int(a)])
        return simd_dot(cross, facing) > 0 ? [a, b, c, a, c, d] : [a, c, b, a, d, c]
    }
}

/// The box's edges (see `BoxEdges`), for `DaySystem` to light with the time
/// of day.
struct BoxEdgesComponent: Component {
    /// The light the bevels were last lit in.
    var light: SIMD3<Float> = [-1, -1, -1]
}
