import Foundation

/// Represents the persona attributes of a social agent, stored as JSON in `social_agent.persona_json`.
struct AgentPersona: Codable, Sendable, Equatable {
    var age: Int?
    var profession: String?
    var interests: [String]
    var mbti: String?
    var sentimentBias: Double
    var stance: String?
    var influenceWeight: Double

    init(
        age: Int? = nil,
        profession: String? = nil,
        interests: [String] = [],
        mbti: String? = nil,
        sentimentBias: Double = 0.0,
        stance: String? = nil,
        influenceWeight: Double = 0.5
    ) {
        self.age = age
        self.profession = profession
        self.interests = interests
        self.mbti = mbti
        self.sentimentBias = sentimentBias
        self.stance = stance
        self.influenceWeight = influenceWeight
    }
}
