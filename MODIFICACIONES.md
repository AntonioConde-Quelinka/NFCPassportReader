# Modificaciones locales sobre NFCPassportReader

Copia local de la versión **2.3.3** (commit `6e37f1a`) de
https://github.com/AndyQ/NFCPassportReader

Se clonó porque la librería no expone el canal seguro que establece PACE:
`TagReader.init` y `TagReader.send` son `internal`, así que desde la app no hay
forma de enviar APDUs propias sobre ese canal.

## Cambios

### `Sources/NFCPassportReader/TagReader.swift`
Se añade `public func sendUnchecked(cmd:useExtendedMode:)`. Igual que `send`,
pero devuelve la respuesta tal cual en lugar de lanzar cuando el estado no es
9000. Un sondeo necesita leer un `6982` como dato, no como excepción.

### `Sources/NFCPassportReader/PassportReader.swift`
Se añade `public var secureChannelProbe: ((TagReader) async -> Void)?`, que se
invoca tras leer y verificar todos los grupos de datos y antes de cerrar la
sesión NFC. Va al final a propósito: si lo que se envía rompe el canal o cambia
la aplicación seleccionada, la lectura del documento ya está completa.

Ningún cambio altera el comportamiento existente: sin asignar
`secureChannelProbe`, la librería se comporta exactamente igual que la original.

## Para volver a la versión oficial
Basta con quitar el paquete local en Xcode y volver a añadir la dependencia
remota apuntando a la 2.3.3. Se perdería el sondeo del canal seguro.

## Nota sobre `SecureMessaging.unprotect`

`unprotect` abandona el desenvolvimiento y devuelve la respuesta protegida tal
cual cuando el estado exterior de la APDU no es 9000:

```swift
if(rapdu.sw1 != 0x90 || rapdu.sw2 != 0x00) {
    return rapdu
}
```

El DNIe repite el 6282 de «fin de fichero» en el estado exterior incluso cuando
la lectura ha sido correcta y trae datos, así que por esa vía el contenido nunca
llega a descifrarse. Peor: no lanza, de modo que quien llama no puede distinguir
el sobre del contenido.

`sendUnchecked` lo sortea normalizando el estado exterior a 9000 cuando la
respuesta tiene forma de sobre (empieza por DO'87 o DO'99). El estado real se
toma del DO'99, que es lo que devuelve `unprotect`. No se toca el original para
no alterar el comportamiento del resto de la librería.

## Fallo corregido: comparación de MAC tautológica con AES

### `Sources/NFCPassportReader/SecureMessaging.swift`

En la verificación del MAC de la respuesta, el truncamiento a ocho bytes se
aplicaba sobre `CC` (el MAC recibido) en lugar de sobre `CCb` (el calculado):

```swift
var CCb = mac(algoName: algoName, key: self.ksmac, msg: K)
if CCb.count > 8 {
    CCb = [UInt8](CC[0..<8])   // usaba CC, el recibido, en lugar de CCb
}
```

Si el MAC calculado pasa de ocho bytes, eso sustituye el calculado por el
recibido y la comparación de más abajo (`CC == CCb`) se vuelve tautológica.
Con 3DES el MAC son ocho bytes justos y no se disparaba; con AES sí. Se
corrige truncando `CCb`, que es lo que tiene sentido comparar contra `CC`.

## `Sendable` para consumo desde Swift 6

### `Sources/NFCPassportReader/ConcurrencyBoundary.swift` (nuevo)

La app consumidora (Swift-DNIe) migra a modo de lenguaje Swift 6 con
comprobación estricta de concurrencia. `TagReader`, `PassportReader` y
`NFCPassportModel` cruzan la frontera async hacia esa app (se pasan a
funciones `async`, se devuelven desde `readPassport`, se capturan en el
closure de `secureChannelProbe`) sin llevar ninguna anotación de
concurrencia, así que el compilador los trata como no seguros de mover entre
dominios de aislamiento.

Se añaden conformidades `@unchecked Sendable` (y `Sendable` simple para
`ResponseAPDU`/`TagReader.UncheckedResponse`, que son structs con solo
campos ya `Sendable`) en un fichero nuevo, sin tocar las clases originales.
Es deliberadamente una fachada mínima: no se audita el resto de la
librería (parsers de grupos de datos, ASN.1, criptografía) porque el patrón
de uso real —una única instancia por sesión NFC, recorrida de forma
estrictamente secuencial con `await`— ya cumple por construcción las
garantías que pide `Sendable`; el `unchecked` solo reconoce que el
compilador no puede demostrarlo sin anotación explícita.
