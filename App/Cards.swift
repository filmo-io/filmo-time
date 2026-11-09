import SwiftUI

// MARK: - Card catalogue
//
// Film posters come from TMDB's image CDN (no key needed) and are only cached on
// this Mac; historical photos are public domain or CC images from Wikimedia Commons.

enum Rarity: Int, Codable, CaseIterable, Comparable {
    case common, rare, epic, legendary

    static func < (a: Rarity, b: Rarity) -> Bool { a.rawValue < b.rawValue }

    var name: String { ["Común", "Rara", "Épica", "Legendaria"][rawValue] }
    var colors: [Color] {
        switch self {
        case .common: [hex(0xC9CED4), hex(0x7C848E)]
        case .rare: [hex(0x7CCBFF), hex(0x2F6FE0)]
        case .epic: [hex(0xDDA0FF), hex(0x7B3FE4)]
        case .legendary: [hex(0xFFE58F), hex(0xF08A24)]
        }
    }
    var gradient: LinearGradient { LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing) }
    /// Tokens a repeated card turns into.
    var tokens: Int { [1, 3, 8, 25][rawValue] }
    /// Tokens it takes to make one you are missing.
    var craftCost: Int { [12, 45, 160, 400][rawValue] }
}

enum CardArt {
    case poster(String)
    case photo(String, credit: String)
    /// Drawn in the app: a symbol on a gradient, for moments with no free image.
    case drawn(String, [UInt32])
    /// A company of the industry, as a wordmark.
    case brand([UInt32])
    /// A company with its logo, on its brand colour. The logo ships inside the app (Resources/logos/<id>.png).
    case logo(bg: UInt32)

    var url: URL {
        switch self {
        case .poster(let path): URL(string: "https://image.tmdb.org/t/p/w342\(path)")!
        case .photo(let url, _): URL(string: url)!
        case .drawn, .brand, .logo: URL(string: "about:blank")!
        }
    }

    var isDrawn: Bool {
        switch self {
        case .drawn, .brand: true
        default: false
        }
    }
}

struct CardDef: Identifiable, Hashable {
    let id: String
    let title: String
    let year: Int
    let by: String
    let trivia: String
    let rarity: Rarity
    let set: String
    let art: CardArt

    static func == (a: CardDef, b: CardDef) -> Bool { a.id == b.id }
    func hash(into h: inout Hasher) { h.combine(id) }

    var isPhoto: Bool { if case .photo = art { true } else { false } }
    /// "1977", or nothing for companies.
    var yearText: String { year > 0 ? String(year) : "" }
    var credit: String {
        switch art {
        case .poster: "Póster: TMDB"
        case .photo(_, let credit): credit
        case .drawn, .brand, .logo: ""
        }
    }
}

struct CardSet: Identifiable {
    let id: String
    let name: String
    let symbol: String
    var cards: [CardDef] { allCards.filter { $0.set == id } }
}

let cardSets = [
    CardSet(id: "pelis", name: "Películas", symbol: "film.fill"),
    CardSet(id: "series", name: "Series", symbol: "tv.fill"),
    CardSet(id: "industria", name: "Industria", symbol: "camera.fill"),
    CardSet(id: "filmo", name: "Filmo", symbol: "star.fill"),
]

private let commons = "https://upload.wikimedia.org/wikipedia/commons"

private let baseCards: [CardDef] = [
    // Éxitos de taquilla
    CardDef(id: "padrino", title: "El padrino", year: 1972, by: "Francis Ford Coppola",
            trivia: "La saga de la familia Corleone que redefinió el cine de mafiosos y ganó el Óscar a mejor película.",
            rarity: .legendary, set: "pelis", art: .poster("/5HlLUsmsv60cZVTzVns9ICZD6zU.jpg")),
    CardDef(id: "titanic", title: "Titanic", year: 1997, by: "James Cameron",
            trivia: "Romance y catástrofe a bordo del célebre transatlántico: ganó once Óscar y batió todos los récords de taquilla.",
            rarity: .epic, set: "pelis", art: .poster("/2tltWMvvTqscFtdujTXDsRFTqKQ.jpg")),
    CardDef(id: "jurassic-park", title: "Jurassic Park", year: 1993, by: "Steven Spielberg",
            trivia: "La aventura de dinosaurios clonados cuyos efectos digitales revolucionaron para siempre los efectos visuales en el cine.",
            rarity: .epic, set: "pelis", art: .poster("/1r8TWaAExHbFRzyqT3Vcbq1XZQb.jpg")),
    CardDef(id: "tiburon", title: "Tiburón", year: 1975, by: "Steven Spielberg",
            trivia: "El thriller del tiburón asesino que inventó el concepto de taquillazo de verano en Hollywood.",
            rarity: .epic, set: "pelis", art: .poster("/aCqHb3eFQV8raX30OfGurqPlpjh.jpg")),
    CardDef(id: "casablanca", title: "Casablanca", year: 1942, by: "Michael Curtiz",
            trivia: "El gran clásico romántico del Hollywood dorado, ambientado en la Segunda Guerra Mundial y ganador del Óscar a mejor película.",
            rarity: .rare, set: "pelis", art: .poster("/a7EjycGNSYw6QqJqDooD9eQGZ4r.jpg")),
    CardDef(id: "pulp-fiction", title: "Pulp Fiction", year: 1994, by: "Quentin Tarantino",
            trivia: "Historias criminales cruzadas en orden no lineal que consagraron a Tarantino y revolucionaron el cine independiente de los noventa.",
            rarity: .rare, set: "pelis", art: .poster("/hNcQAuquJxTxl2fJFs1R42DrWcf.jpg")),
    CardDef(id: "toy-story", title: "Toy Story", year: 1995, by: "John Lasseter",
            trivia: "La aventura de los juguetes de Andy, primer largometraje hecho íntegramente por ordenador y punto de partida de Pixar.",
            rarity: .common, set: "pelis", art: .poster("/jvn7wy3RSNEXnFSXLpH2of2LcV6.jpg")),
    CardDef(id: "shrek", title: "Shrek", year: 2001, by: "Andrew Adamson y Vicky Jenson",
            trivia: "Un ogro que parodia los cuentos de hadas y ganó el primer Óscar a mejor película de animación.",
            rarity: .common, set: "pelis", art: .poster("/jTQONM7jt1yv2lL972TtmWO0UIZ.jpg")),

    // Ciencia ficción
    CardDef(id: "star-wars", title: "La guerra de las galaxias", year: 1977, by: "George Lucas",
            trivia: "La ópera espacial de George Lucas que inauguró el cine de franquicias y revolucionó los efectos especiales.",
            rarity: .legendary, set: "pelis", art: .poster("/4hOUzmButYUeON0prG3RpbqS7ag.jpg")),
    CardDef(id: "regreso-futuro", title: "Regreso al futuro", year: 1985, by: "Robert Zemeckis",
            trivia: "La comedia de viajes en el tiempo de Marty McFly y Doc Brown, icono del cine de aventuras de los ochenta.",
            rarity: .legendary, set: "pelis", art: .poster("/owk40tn1sFJmC7bhamEpmhdZPKa.jpg")),
    CardDef(id: "matrix", title: "Matrix", year: 1999, by: "Lana y Lilly Wachowski",
            trivia: "Ciencia ficción ciberpunk sobre una realidad simulada que popularizó el «bullet time» y transformó el cine de acción.",
            rarity: .epic, set: "pelis", art: .poster("/tpW2X2DvxtTHJ61iJ7zNYYrJihs.jpg")),
    CardDef(id: "alien", title: "Alien", year: 1979, by: "Ridley Scott",
            trivia: "La fusión de terror y ciencia ficción que convirtió a Ripley y al xenomorfo en iconos del género.",
            rarity: .rare, set: "pelis", art: .poster("/pZ9cAe5FxexJjpCaeiETbXzz3Fs.jpg")),
    CardDef(id: "blade-runner", title: "Blade Runner", year: 1982, by: "Ridley Scott",
            trivia: "La historia de un cazador de replicantes cuya estética futurista definió el imaginario ciberpunk en el cine.",
            rarity: .rare, set: "pelis", art: .poster("/pBA2J6iQMiP5Zd4ewMKdOWfq1HV.jpg")),
    CardDef(id: "et", title: "E.T., el extraterrestre", year: 1982, by: "Steven Spielberg",
            trivia: "La amistad entre un niño y un extraterrestre perdido, uno de los títulos más queridos y taquilleros de Spielberg.",
            rarity: .rare, set: "pelis", art: .poster("/ojvKem8WUzRK5PLvO7wTuAFinnz.jpg")),
    CardDef(id: "origen", title: "Origen", year: 2010, by: "Christopher Nolan",
            trivia: "Un thriller de robos dentro de los sueños que combinó cine de autor, gran espectáculo y efectos prácticos.",
            rarity: .common, set: "pelis", art: .poster("/tXQvtRWfkUUnWJAn2tN3jERIUG.jpg")),
    CardDef(id: "interstellar", title: "Interstellar", year: 2014, by: "Christopher Nolan",
            trivia: "Odisea espacial en busca de un nuevo hogar para la humanidad, célebre por su riguroso retrato de un agujero negro.",
            rarity: .common, set: "pelis", art: .poster("/d1QKiYtceF3GDtxvTFXFAqwwah9.jpg")),

    // Cine español
    CardDef(id: "laberinto-fauno", title: "El laberinto del fauno", year: 2006, by: "Guillermo del Toro",
            trivia: "Fábula oscura en la España de la posguerra que mezcla fantasía y realidad y ganó tres Óscar.",
            rarity: .epic, set: "pelis", art: .poster("/gWPkUFGlO7ZIiArUcWRBmvAwVjB.jpg")),
    CardDef(id: "todo-sobre-mi-madre", title: "Todo sobre mi madre", year: 1999, by: "Pedro Almodóvar",
            trivia: "Melodrama de Almodóvar sobre maternidad y pérdida que ganó el Óscar a mejor película de habla no inglesa.",
            rarity: .rare, set: "pelis", art: .poster("/evvT3HUwoQYoPQXWFO10R6AvhxG.jpg")),
    CardDef(id: "ocho-apellidos", title: "Ocho apellidos vascos", year: 2014, by: "Emilio Martínez-Lázaro",
            trivia: "Comedia sobre el choque cultural entre andaluces y vascos, convertida en la película española más taquillera en España.",
            rarity: .common, set: "pelis", art: .poster("/9212udpJsvp01Cb5RkoKEpchtpX.jpg")),
    CardDef(id: "campeones", title: "Campeones", year: 2018, by: "Javier Fesser",
            trivia: "Comedia sobre un equipo de baloncesto de jugadores con discapacidad intelectual que ganó el Goya a mejor película.",
            rarity: .common, set: "pelis", art: .poster("/lXLKmT6mtizYvweAgPXVHs0ApvR.jpg")),
    CardDef(id: "mar-adentro", title: "Mar adentro", year: 2004, by: "Alejandro Amenábar",
            trivia: "La lucha de Ramón Sampedro por una muerte digna, ganadora del Óscar a mejor película de habla no inglesa.",
            rarity: .common, set: "pelis", art: .poster("/6mGgn60Riv14B3zPjTNNZnFHp3c.jpg")),
    CardDef(id: "orfanato", title: "El orfanato", year: 2007, by: "J. A. Bayona",
            trivia: "Debut de Bayona y referente del terror español moderno, con un éxito de taquilla y crítica dentro y fuera de España.",
            rarity: .common, set: "pelis", art: .poster("/wk95EOzZKd74NFzVVkHBo1UW46o.jpg")),
    CardDef(id: "torrente", title: "Torrente", year: 1998, by: "Santiago Segura",
            trivia: "La comedia gamberra de Santiago Segura sobre un policía impresentable que dio origen a la saga más taquillera del cine español.",
            rarity: .common, set: "pelis", art: .poster("/wsVBpaeOpd4wfDYMQid1prYgFUD.jpg")),
    CardDef(id: "los-otros", title: "Los otros", year: 2001, by: "Alejandro Amenábar",
            trivia: "Historia de fantasmas rodada en inglés con Nicole Kidman, éxito internacional y ganadora de ocho Goyas, incluido mejor película.",
            rarity: .common, set: "pelis", art: .poster("/u03kblxsv3zar3Uqt6sRfICU9L6.jpg")),

    // Series
    CardDef(id: "juego-de-tronos", title: "Juego de tronos", year: 2011, by: "HBO",
            trivia: "La adaptación de las novelas de George R. R. Martin que llevó la fantasía épica y la escala del cine a la televisión.",
            rarity: .legendary, set: "series", art: .poster("/3hDtRuwTfQQYRst3kjhvp4Cogjw.jpg")),
    CardDef(id: "breaking-bad", title: "Breaking Bad", year: 2008, by: "Vince Gilligan",
            trivia: "La transformación de un profesor de química en narcotraficante, considerada una de las mejores series dramáticas de la historia.",
            rarity: .legendary, set: "series", art: .poster("/anFx9aTOOYqgS3v7x3R84Kz67ly.jpg")),
    CardDef(id: "simpson", title: "Los Simpson", year: 1989, by: "Matt Groening",
            trivia: "La familia amarilla de Springfield, la serie de animación más longeva y un referente de la sátira televisiva.",
            rarity: .epic, set: "series", art: .poster("/9hmoEmntaYrrlb4HKSFisWUQnqy.jpg")),
    CardDef(id: "soprano", title: "Los Soprano", year: 1999, by: "David Chase",
            trivia: "El drama de un mafioso de Nueva Jersey en terapia que inauguró la edad de oro de la televisión de calidad.",
            rarity: .epic, set: "series", art: .poster("/p7XPjx5jTFl32TGbbIW8exdY8QW.jpg")),
    CardDef(id: "casa-de-papel", title: "La casa de papel", year: 2017, by: "Álex Pina",
            trivia: "El atraco a la Fábrica Nacional de Moneda y Timbre que convirtió una serie española en fenómeno mundial de Netflix.",
            rarity: .epic, set: "series", art: .poster("/z01Dc0Ly2GmCpLe6Scx4d3dPP1S.jpg")),
    CardDef(id: "friends", title: "Friends", year: 1994, by: "David Crane y Marta Kauffman",
            trivia: "Seis amigos en Nueva York protagonizan una de las comedias de situación más populares y reemitidas de la televisión.",
            rarity: .rare, set: "series", art: .poster("/rkKCSlr8OH5tbKEdgwtzvEiemrl.jpg")),
    CardDef(id: "stranger-things", title: "Stranger Things", year: 2016, by: "Hermanos Duffer",
            trivia: "Misterio sobrenatural y nostalgia de los años ochenta en uno de los mayores fenómenos de la historia de Netflix.",
            rarity: .rare, set: "series", art: .poster("/AsPD90QEQsIAtSxfSjV3fN7XFpt.jpg")),
    CardDef(id: "the-office", title: "The Office", year: 2005, by: "Greg Daniels",
            trivia: "Comedia en formato de falso documental sobre una oficina de Scranton, adaptación del original británico convertida en clásico.",
            rarity: .rare, set: "series", art: .poster("/5uwetbr0X8BPRy3Wmh63S9EhsiY.jpg")),
    CardDef(id: "twin-peaks", title: "Twin Peaks", year: 1990, by: "David Lynch y Mark Frost",
            trivia: "El misterio de la muerte de Laura Palmer con el que David Lynch llevó el cine de autor a la televisión.",
            rarity: .rare, set: "series", art: .poster("/lA9CNSdo50iQPZ8A2fyVpMvJZAf.jpg")),
    CardDef(id: "black-mirror", title: "Black Mirror", year: 2011, by: "Charlie Brooker",
            trivia: "Antología de historias independientes sobre el lado oscuro de la tecnología, referente de la ciencia ficción televisiva actual.",
            rarity: .common, set: "series", art: .poster("/pY80haDeUJLHjWLW7edqWaQ2UfW.jpg")),
    CardDef(id: "aqui-no-hay", title: "Aquí no hay quien viva", year: 2003, by: "Alberto y Laura Caballero",
            trivia: "La comedia de los vecinos de Desengaño 21, una de las series españolas más vistas y reemitidas de la televisión.",
            rarity: .common, set: "series", art: .poster("/db9cSJfLugDSGfsW4tqMTPGupVT.jpg")),
    CardDef(id: "ministerio", title: "El ministerio del tiempo", year: 2015, by: "Javier y Pablo Olivares",
            trivia: "Una patrulla secreta que viaja por la historia de España, referente de la ficción fantástica en la televisión española.",
            rarity: .common, set: "series", art: .poster("/sNv6aE47PTTTpHknT3gzmF2rBgh.jpg")),
    CardDef(id: "cuentame", title: "Cuéntame cómo pasó", year: 2001, by: "TVE",
            trivia: "La historia de la familia Alcántara desde el tardofranquismo, la serie de ficción más longeva del prime time español.",
            rarity: .common, set: "series", art: .poster("/lF0ip8ZAvweDTuhMaUD1dH3SYhs.jpg")),

    // Industria
    CardDef(id: "luna", title: "La Luna en directo", year: 1969, by: "Apolo 11 · NASA",
            trivia: "La llegada del Apolo 11 a la Luna, seguida en directo por cientos de millones de personas: un hito de la televisión mundial.",
            rarity: .legendary, set: "industria",
            art: .photo("\(commons)/thumb/9/98/Aldrin_Apollo_11_original.jpg/500px-Aldrin_Apollo_11_original.jpg",
                        credit: "Foto: Neil Armstrong / NASA · dominio público")),
    CardDef(id: "lumiere", title: "La primera sesión de cine", year: 1895, by: "Hermanos Lumière",
            trivia: "Los Lumière proyectaron películas ante público de pago en París, considerado el nacimiento del cine como espectáculo.",
            rarity: .epic, set: "industria",
            art: .photo("\(commons)/0/0f/La_sortie_des_usines_Lumiere.jpg",
                        credit: "Fotograma: Louis Lumière · dominio público")),
    CardDef(id: "cantor-de-jazz", title: "Llega el cine sonoro", year: 1927, by: "El cantor de jazz",
            trivia: "«El cantor de jazz», primer largometraje con diálogos sincronizados, abrió el paso del cine mudo al sonoro.",
            rarity: .epic, set: "industria", art: .poster("/zYxe070bHAihohoZlV2uHDJCHqD.jpg")),
    CardDef(id: "viaje-luna", title: "Los primeros efectos especiales", year: 1902, by: "Georges Méliès",
            trivia: "Con «Viaje a la Luna», Méliès usó trucos de cámara y decorados fantásticos que sentaron las bases de los efectos especiales.",
            rarity: .rare, set: "industria",
            art: .photo("\(commons)/0/04/Le_Voyage_dans_la_lune.jpg",
                        credit: "Fotograma: Georges Méliès · dominio público")),
    CardDef(id: "oscars", title: "La primera gala de los Óscar", year: 1929, by: "Hollywood",
            trivia: "La Academia de Hollywood entregó sus primeros premios, origen de los galardones más famosos de la historia del cine.",
            rarity: .rare, set: "industria", art: .photo("https://thumb.wikimedia.org/wikipedia/commons/thumb/4/4c/Lewis_Milestone_Best_Comedy_Director_1929.jpg/500px-Lewis_Milestone_Best_Comedy_Director_1929.jpg", credit: "Foto: Academy of Motion Picture Arts and Sciences · dominio público")),
    CardDef(id: "hollywood", title: "El cartel de Hollywood", year: 1923, by: "Los Ángeles",
            trivia: "Nació como anuncio inmobiliario y acabó convertido en el símbolo mundial de la industria del cine estadounidense.",
            rarity: .common, set: "industria",
            art: .photo("\(commons)/thumb/5/5a/Hollywood_Sign_%28Zuschnitt%29.jpg/500px-Hollywood_Sign_%28Zuschnitt%29.jpg",
                        credit: "Foto: Thomas Wolf, foto-tw.de · CC BY-SA 3.0")),
    CardDef(id: "goya", title: "Los primeros Goya", year: 1987, by: "Academia de Cine",
            trivia: "La Academia de Cine entregó los primeros Goya, desde entonces los principales premios del cine español.",
            rarity: .common, set: "industria", art: .photo("https://thumb.wikimedia.org/wikipedia/commons/thumb/5/55/Premio_Goya_Valladolid_2024_01.jpg/500px-Premio_Goya_Valladolid_2024_01.jpg", credit: "Foto: MiguelAlanCS · CC BY-SA 4.0")),
    CardDef(id: "cannes", title: "El primer Festival de Cannes", year: 1946, by: "Cannes",
            trivia: "Nace el Festival de Cannes, que se convertiría en el escaparate más prestigioso del cine de autor internacional.",
            rarity: .common, set: "industria", art: .photo("https://thumb.wikimedia.org/wikipedia/commons/thumb/7/70/Main_Cast_of_Un_Simple_Accident_at_the_top_of_Cannes_Red_Carpet_Steps.jpg/500px-Main_Cast_of_Un_Simple_Accident_at_the_top_of_Cannes_Red_Carpet_Steps.jpg", credit: "Foto: Kacy Bao · CC BY-SA 4.0")),

]

/// Every card in the Filmedex.
let allCards: [CardDef] = baseCards + moreCards + filmoCards + eventCards

// MARK: - Packs

struct PackKind: Identifiable {
    let id: String
    let name: String
    let price: Int
    let count: Int
    /// Chance of each rarity for every card: common, rare, epic, legendary (sums to 100).
    let odds: [Double]
    let colors: [Color]
}

let packKinds = [
    PackKind(id: "taquilla", name: "Pre-seed", price: 36, count: 2, odds: [80, 18, 1.8, 0.2],
             colors: [hex(0xE9E4D8), hex(0xA89F8C)]),
    PackKind(id: "estreno", name: "Seed", price: 90, count: 2, odds: [62, 30, 7, 1],
             colors: [hex(0x6FB6FF), hex(0x23439C)]),
    PackKind(id: "gala", name: "Serie A", price: 130, count: 3, odds: [33, 40, 25, 2],
             colors: [hex(0xC58CFF), hex(0x4A1E8C)]),
    PackKind(id: "alfombra", name: "IPO", price: 250, count: 3, odds: [22, 43, 27, 8],
             colors: [hex(0xFF6B6B), hex(0x8E0E1E)]),
]

/// The free pack of each full workday: one card with Taquilla odds.
let dailyPack = PackKind(id: "diario", name: "Sobre del día", price: 0, count: 1, odds: [80, 18, 1.8, 0.2],
                         colors: [hex(0xFFE3A3), hex(0xC98A2E)])

func pack(_ id: String) -> PackKind { (packKinds + [dailyPack]).first { $0.id == id } ?? packKinds[0] }

/// "0,5 %", "15 %".
func percent(_ v: Double) -> String {
    let f = NumberFormatter()
    f.locale = Locale(identifier: "es_ES")
    f.maximumFractionDigits = 1
    return "\(f.string(from: v as NSNumber) ?? "\(v)") %"
}
