import Foundation
import NaturalLanguage

/// Reconocimiento de objetos en el guion y su clasificación por departamento.
/// `detect` extrae sustantivos (lematizados) de un texto con NaturalLanguage; `classify` usa un
/// diccionario integrado para proponer el departamento. Es una ayuda para curar el desglose, no una
/// verdad absoluta: las decisiones manuales del usuario (añadir, quitar, reasignar) mandan sobre esto.
enum ScriptProps {

    // MARK: - Detección de sustantivos

    private static var cache: [Int: [String]] = [:]

    /// Sustantivos que casi nunca son un ítem de desglose (tiempo, cuerpo, abstracciones).
    private static let stop: Set<String> = [
        "día", "días", "noche", "noches", "mañana", "tarde", "momento", "vez", "veces", "rato", "instante",
        "hora", "horas", "minuto", "minutos", "segundo", "segundos", "tiempo", "año", "años", "semana", "mes",
        "cosa", "cosas", "lado", "parte", "partes", "forma", "manera", "modo", "tipo", "clase",
        "voz", "mirada", "silencio", "gesto", "sonrisa", "grito", "paso", "pasos",
        "aire", "frío", "calor", "dolor", "miedo", "vida", "muerte",
        "mano", "manos", "cara", "rostro", "ojo", "ojos", "cabeza", "pelo", "pie", "pies", "cuerpo",
        "brazo", "brazos", "pierna", "piernas", "boca", "dedo", "dedos", "espalda", "hombro", "cuello",
        "hombre", "mujer", "niño", "niña", "gente", "persona", "personas", "señor", "señora", "chico", "chica",
        "palabra", "palabras", "nombre", "historia", "idea", "mundo",
        "final", "principio", "fondo", "frente", "centro", "medio", "vista", "punto", "nada", "algo", "todo",
    ]

    /// Sustantivos (lemas en minúscula, en orden de aparición y sin repetir) del texto dado. Cacheado.
    static func detect(in text: String) -> [String] {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return [] }
        let key = t.hashValue
        if let hit = cache[key] { return hit }

        let tagger = NLTagger(tagSchemes: [.lexicalClass, .lemma])
        let opts: NLTagger.Options = [.omitPunctuation, .omitWhitespace, .omitOther]
        var seen = Set<String>()
        var out: [String] = []
        let range = t.startIndex..<t.endIndex
        tagger.string = t
        tagger.setLanguage(.spanish, range: range)
        tagger.enumerateTags(in: range, unit: .word, scheme: .lexicalClass, options: opts) { tag, tokenRange in
            guard tag == .noun else { return true }
            let lemma = tagger.tag(at: tokenRange.lowerBound, unit: .word, scheme: .lemma).0?.rawValue
            let raw = String(t[tokenRange])
            var name = (lemma.map { $0.isEmpty ? raw : $0 } ?? raw).lowercased()
            name = name.trimmingCharacters(in: .punctuationCharacters)
            guard name.count >= 3, name.first?.isLetter == true, !stop.contains(name) else { return true }
            if seen.insert(name).inserted { out.append(name) }
            return true
        }

        if cache.count > 80 { cache.removeAll() }   // poda simple: el guion activo se recalcula entero
        cache[key] = out
        return out
    }

    // MARK: - Clasificación por diccionario

    /// Departamento sugerido para un objeto (lema en minúscula), o nil si no está en el diccionario.
    static func classify(_ noun: String) -> Department? { lexicon[noun] }

    private static let lexicon: [String: Department] = {
        var m: [String: Department] = [:]
        func add(_ dept: Department, _ words: [String]) { for w in words { m[w] = dept } }

        add(.props, [
            "cuchillo", "navaja", "pistola", "arma", "revólver", "rifle", "espada", "martillo",
            "destornillador", "llave", "llaves", "teléfono", "celular", "móvil", "cámara", "reloj",
            "anillo", "collar", "pulsera", "cartera", "billetera", "bolso", "mochila", "maleta",
            "paraguas", "bastón", "cigarrillo", "cigarro", "encendedor", "fósforo", "vela",
            "libro", "cuaderno", "carta", "sobre", "documento", "papel", "foto", "fotografía", "mapa",
            "vaso", "copa", "taza", "botella", "jarra", "termo", "plato", "cuchara", "tenedor", "olla",
            "dinero", "billete", "moneda", "pastilla", "frasco", "jeringa", "guitarra", "violín",
            "pelota", "balón", "juguete", "muñeca", "rosa", "flor", "ramo", "regalo", "caja", "bolsa",
            "cuerda", "linterna", "radio", "periódico", "revista", "lápiz", "pluma", "bolígrafo",
        ])
        add(.setDressing, [
            "mesa", "silla", "sillón", "sofá", "cama", "escritorio", "estante", "estantería", "librero",
            "armario", "ropero", "cómoda", "cajón", "lámpara", "cuadro", "espejo", "alfombra", "cortina",
            "cortinas", "florero", "planta", "maceta", "reloj", "televisor", "televisión", "nevera",
            "refrigerador", "heladera", "horno", "cocina", "lavabo", "bañera", "inodoro", "escalera",
            "chimenea", "ventilador", "mostrador", "banco", "banca", "mesada", "repisa", "perchero",
            "puerta", "ventana", "pizarra", "cartel", "letrero", "estatua", "farol",
        ])
        add(.wardrobe, [
            "camisa", "camiseta", "blusa", "polera", "pantalón", "vaquero", "jean", "vestido", "falda",
            "chaqueta", "abrigo", "saco", "chaleco", "suéter", "sudadera", "traje", "uniforme", "bata",
            "pijama", "zapato", "zapatos", "zapatilla", "zapatillas", "bota", "botas", "sandalia",
            "sombrero", "gorra", "gorro", "boina", "bufanda", "guante", "guantes", "corbata", "cinturón",
            "calcetín", "calcetines", "media", "medias", "capa", "delantal", "gafas", "lentes", "anteojos",
        ])
        add(.lighting, ["antorcha", "neón", "reflector", "candelabro", "lámpara"])
        add(.sound, ["parlante", "altavoz", "bocina", "megáfono", "micrófono", "campana", "sirena", "timbre"])
        // Nota: algunas palabras valen para dos departamentos (lámpara, reloj, radio); gana la última
        // asignación de este bloque. El usuario puede reasignar con un toque.
        return m
    }()
}
