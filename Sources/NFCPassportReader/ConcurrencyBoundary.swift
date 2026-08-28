//
//  ConcurrencyBoundary.swift
//  NFCPassportReader
//
//  Añadido sobre la versión 2.3.3 de la librería. Ver MODIFICACIONES.md.
//

/// Conformidades `Sendable` para el pequeño conjunto de tipos que cruzan la
/// frontera async hacia la app consumidora (Swift-DNIe).
///
/// Es una fachada deliberadamente mínima: no se audita el resto de la
/// librería (parsers de grupos de datos, ASN.1, criptografía...) porque
/// nunca se usa desde más de una tarea a la vez. Cada `TagReader` y
/// `PassportReader` vive dentro de una única sesión NFC, recorrida de forma
/// estrictamente secuencial con `await`: no hay dos llamadas en vuelo a la
/// vez sobre la misma instancia, así que las garantías reales que exige
/// `Sendable` ya se cumplen por construcción del flujo, aunque el
/// compilador no pueda demostrarlo por sí solo al no anotar las clases.

#if !os(macOS)
extension TagReader: @unchecked Sendable {}
extension PassportReader: @unchecked Sendable {}
extension TagReader.UncheckedResponse: Sendable {}
extension ResponseAPDU: Sendable {}
#endif

extension NFCPassportModel: @unchecked Sendable {}
