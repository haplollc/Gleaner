import Foundation

/// Invented data for a made-up person ("Alex"): liked posts and searches from an imaginary export.
/// Nothing here comes from a real person. Rare interests are planted on purpose so the demo can check
/// whether an approach noticed them.
struct SampleData {
    struct Interest {
        let name: String
        let weight: Double              // share of the personal records
        let olderOnly: Bool             // concentrated in the older 60% of the export
        let keywords: [String]          // an idea "covers" the interest when its text has one of these
        let posts: [String]
        let searches: [String]
    }

    static let interests: [Interest] = [
        Interest(name: "bouldering", weight: 0.15, olderOnly: false, keywords: ["climb", "bouldering", "chalk"],
                 posts: ["Gym day: finally sent the purple V4 on the cave wall", "New chalk bag drop from a small brand, hand stitched", "Beginner bouldering tips: footwork before strength", "Climbing shoe resole before and after", "Fingerboard hangs for tendon health, a thread"],
                 searches: ["best bouldering shoes for wide feet", "climbing gym near me day pass", "how to stop pumping out on overhangs", "finger tape for climbing", "chalk bag with brush holder"]),
        Interest(name: "specialty coffee", weight: 0.13, olderOnly: false, keywords: ["coffee", "pour-over", "pour over", "espresso", "grinder", "brew"],
                 posts: ["Pour-over ratio cheat sheet: 1:16 and a 30 second bloom", "Hand grinder showdown: burrs matter more than price", "Single origin from Ethiopia tastes like blueberry jam", "My morning V60 routine, kettle with a gooseneck", "Latte art practice, day 40"],
                 searches: ["gooseneck kettle with temperature control", "best hand grinder under 150", "how long to bloom coffee", "coffee scale with timer", "where to buy fresh roasted beans"]),
        Interest(name: "sourdough baking", weight: 0.11, olderOnly: false, keywords: ["sourdough", "bread", "baking", "dutch oven", "banneton", "starter", "dough"],
                 posts: ["Feeding schedule for a sleepy sourdough starter", "Open crumb at last: higher hydration and a longer fold", "Dutch oven bread, the crust crackles when it cools", "Banneton baskets: cane or wood pulp?", "Scoring patterns for a boule, wheat stalk edition"],
                 searches: ["banneton proofing basket round", "bread lame replacement blades", "what is autolyse", "dutch oven 5 quart", "digital scale 0.1g"]),
        Interest(name: "houseplants", weight: 0.09, olderOnly: false, keywords: ["plant", "fern", "monstera", "pothos", "fig", "terrarium", "repot"],
                 posts: ["Why your fiddle leaf fig is dropping leaves", "Propagating pothos in water, week three roots", "Repotting a monstera without crying", "Rare calathea spotted at a tiny nursery", "Grow light shelf setup for a dark apartment"],
                 searches: ["self watering planter small", "fiddle leaf fig brown spots", "plant mister brass", "grow light full spectrum clip", "terracotta pots with saucers"]),
        Interest(name: "vinyl records", weight: 0.08, olderOnly: false, keywords: ["vinyl", "record", "turntable", "jazz", "lp"],
                 posts: ["Crate digging finds: a 1972 jazz pressing for five dollars", "Cleaning vinyl with a carbon fiber brush", "Turntable cartridge upgrade, is it audible?", "Blue Note reissue series, worth it", "Record store day lines were wild"],
                 searches: ["record cleaning solution", "turntable under 400", "inner sleeves anti static", "70s soul compilations vinyl", "record frame wall mount"]),
        Interest(name: "trail running", weight: 0.07, olderOnly: false, keywords: ["trail", "running", "ultra", "hydration", "vest", "socks"],
                 posts: ["First 50k training block, week 6 recap", "Trail shoe lugs explained", "Hydration vest vs handheld on long runs", "Sunrise run above the treeline", "Merino socks that survive blisters"],
                 searches: ["trail running socks merino", "hydration vest 10 liter", "headlamp for night running", "anti chafe balm", "trail races near me 2027"]),
        Interest(name: "board games", weight: 0.04, olderOnly: false, keywords: ["board game", "boardgame", "tabletop", "meeple", "deck"],
                 posts: ["Our monthly game night pick: a cozy engine builder", "Insert organizers that fit the whole box", "Solo mode for a worker placement game"],
                 searches: ["board game for two players cozy", "card sleeves 63x88", "game night snacks"]),
        Interest(name: "film photography", weight: 0.04, olderOnly: true, keywords: ["film", "35mm", "photograph", "darkroom", "camera"],
                 posts: ["Shot a roll of 35mm Portra at the farmers market", "Why I still develop film at home", "Pocket film camera, a love letter", "Contact sheet from a weekend trip", "Pushing Tri-X to 1600, results"],
                 searches: ["35mm film bulk loader", "film developing kit black and white", "portra 400 5 pack", "light meter app vs handheld", "photo album archival pages"]),
        Interest(name: "birdwatching", weight: 0.03, olderOnly: true, keywords: ["bird", "binocular", "feeder", "warbler"],
                 posts: ["Warbler migration week, the backyard is alive", "Binocular comparison for beginners", "Hummingbird feeder recipe that is safe", "Dawn chorus recording from the trailhead"],
                 searches: ["birding binoculars 8x32", "field guide to birds of the region", "window bird feeder suction", "bird call app"]),
        Interest(name: "fountain pens", weight: 0.03, olderOnly: true, keywords: ["pen", "ink", "notebook", "journal", "stationery"],
                 posts: ["Fountain pen ink swatches, a deep teal", "Dot grid notebook that handles fountain ink", "Bullet journal spread for the month", "A tiny stationery shop in the old town"],
                 searches: ["fountain pen ink sampler", "dot grid notebook a5 fountain pen friendly", "pen case leather for 3", "washi tape set neutral"]),
    ]

    static let noisePosts = [
        "Meme: when the meeting could have been an email", "Celebrity red carpet looks ranked", "Highlights: last night's game in overtime", "Hot take on a TV finale",
        "Ten airport hacks that are not hacks", "This cat refuses to use the new bed", "Election night live blog", "Stock market recap in one minute",
        "Prank video goes wrong", "Viral dance challenge, round 9", "A skyscraper built in 60 seconds", "Fast food menu changes this month",
        "Weather: storm tracker for the weekend", "Phone leak: next year's flagship colors", "Recipe: five ingredient pasta bake", "Funny dog fails of the week",
    ]
    static let noiseSearches = [
        "weather tomorrow", "how to cancel a subscription", "flight status", "convert pounds to kilograms", "is it a holiday on monday",
        "movie showtimes tonight", "what time does the game start", "nearest pharmacy open now", "how to tie a tie", "traffic to the airport",
        "tax deadline", "lyrics to a song everyone is humming", "phone case clearance", "laptop deals", "how long to boil eggs",
    ]

    static let suffixes = ["saved for later", "again", "week 3", "so good", "for the weekend", "worth a try", "on sale", "from last spring", "two stars off", "with a friend", "under budget", "finally"]

    struct Dataset {
        var posts: [String]
        var searches: [String]
        var all: [String] { posts + searches }
    }

    /// A deterministic generator (SplitMix64) so every run sees the same invented person.
    struct RNG {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
        }
        mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
        mutating func pick<T>(_ a: [T]) -> T { a[Int(next() % UInt64(a.count))] }
    }

    static func make(posts postCount: Int, searches searchCount: Int, seed: UInt64 = 7) -> Dataset {
        var rng = RNG(state: seed)
        func records(count: Int, isPost: Bool) -> [String] {
            var out: [String] = []
            out.reserveCapacity(count)
            for i in 0..<count {
                // Newest first, like an export. Position runs 0 (newest) to 1 (oldest).
                let position = Double(i) / Double(max(1, count - 1))
                if rng.unit() < 0.30 {
                    out.append(isPost ? "Liked: " + rng.pick(noisePosts) : "Searched: " + rng.pick(noiseSearches))
                    continue
                }
                // Pick an interest by weight; older-only interests only appear in the older 60%.
                let pool = interests.filter { !$0.olderOnly || position > 0.4 }
                let total = pool.reduce(0) { $0 + $1.weight * ($1.olderOnly ? 2.2 : 1) }
                var roll = rng.unit() * total
                var chosen = pool[0]
                for item in pool {
                    roll -= item.weight * (item.olderOnly ? 2.2 : 1)
                    if roll <= 0 { chosen = item; break }
                }
                var text = isPost ? rng.pick(chosen.posts) : rng.pick(chosen.searches)
                if rng.unit() < 0.5 { text += " | " + rng.pick(suffixes) }
                out.append((isPost ? "Liked: " : "Searched: ") + text)
            }
            return out
        }
        return Dataset(posts: records(count: postCount, isPost: true), searches: records(count: searchCount, isPost: false))
    }

    /// Which of the person's interests an idea's text touches.
    static func covered(by ideas: [String]) -> [String] {
        let text = ideas.joined(separator: " ").lowercased()
        return interests.filter { i in i.keywords.contains { text.contains($0) } }.map(\.name)
    }

    /// The share of ideas that touch any of the person's real interests.
    static func grounded(_ ideas: [String]) -> Double {
        guard !ideas.isEmpty else { return 0 }
        let hits = ideas.filter { idea in
            let t = idea.lowercased()
            return interests.contains { i in i.keywords.contains { t.contains($0) } }
        }
        return Double(hits.count) / Double(ideas.count)
    }
}
