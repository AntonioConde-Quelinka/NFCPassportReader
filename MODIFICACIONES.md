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

También `DataGroupId`, `NFCPassportReaderError` y `NFCViewDisplayMessage`
(enums sin payload problemático) quedan `Sendable` en el mismo fichero:
aparecen en `exportedDataGroups` y en la firma de `customDisplayMessage`.

### `Sources/NFCPassportReader/PassportReader.swift`

Los dos closures que ya cruzaban hacia la app —`secureChannelProbe` y el
parámetro `customDisplayMessage` de `readPassport` (junto con el
`private var nfcViewDisplayMessageHandler` donde se guarda)— se marcan
`@Sendable`. Sin esa anotación, el compilador trata el propio *paso* del
closure a través de `readPassport` como un cruce de aislamiento inseguro,
independientemente de que los tipos que capture ya sean `Sendable`.

## Instalar un secure messaging propio (canal CWA-14890)

### `Sources/NFCPassportReader/TagReader.swift`

Se añade `public func installSecureMessaging(_ sm: SecureMessaging?)`.

Swift-DNIe necesita, además de PACE, abrir el canal de usuario CWA-14890 para
poder autorizar `VERIFY`/`PSO: Compute Digital Signature` con la clave del
ciudadano (ver `HALLAZGOS-DNIe.md` sección 4 y
`Sources/DNIeSwift/ISO7816/CWA14890-FUENTES.md` en Swift-DNIe). La
orquestación de ese protocolo (MSE:SET, PSO:VERIFY CERTIFICATE, GET
CHALLENGE, INTERNAL/EXTERNAL AUTHENTICATE, derivación de claves de sesión)
vive en Swift-DNIe, no en este fork — pero una vez derivadas las claves, el
`SecureMessaging` resultante necesita instalarse en el `TagReader` para que
`sendUnchecked` lo use, y `secureMessaging` es `internal`.

No se expone un getter (no hace falta leer el objeto de vuelta) ni se hace
`public` la propiedad directamente (más superficie de la necesaria para lo
que se necesita). No se toca `SecureMessaging` en sí: su rama `.DES` ya
implementa 3DES-CBC con relleno ISO 7816-4 y Retail-MAC de ocho octetos
(`buildD08E`/`mac` en `Utils.swift`), que es exactamente lo que exige CWA-14890
para un DNIe 3.0/4.0 (conector "V2" en la terminología de jmulticard, MAC de
ocho octetos, frente al "V1" de DNIe 2.0 con MAC de cuatro) — el nombre del
enum case `.DES` es heredado y engañoso (es 3DES, no DES simple), pero no se
renombra: rompería la API pública del fork.

Ningún cambio altera el comportamiento existente: sin llamarlo, el canal
sigue siendo el que instale PACE o BAC como siempre.

## `maskClassAndPad` descartaba el CLA real de la APDU

### `Sources/NFCPassportReader/SecureMessaging.swift`

Al proteger una APDU, `maskClassAndPad` sustituía el byte de clase por un
`0x0c` fijo:

```swift
let res = pad([0x0c, apdu.instructionCode, apdu.p1Parameter, apdu.p2Parameter], blockSize: padLength)
```

Para los comandos ICAO estándar de esta librería (siempre `CLA=0x00`) no se
nota: `0x00 | 0x0C = 0x0C`. Pero CWA-14890 (ver la entrada anterior) necesita
enviar bajo secure messaging un comando propietario del DNIe con `CLA=0x90`
(`GetChipInfo`), y ese `0x90` se perdía por completo, sustituido por `0x0c` —
la tarjeta veía `CLA=0x0C, INS=0xB8`, que no es una instrucción reconocible, y
respondía `6D00`. Confirmado contra tarjeta física: enviar el mismo comando
*sin* secure messaging tampoco vale (`6987`, "falta un objeto de secure
messaging") — la tarjeta exige el canal activo para este paso, así que la
única solución es que el CLA sobreviva dentro del sobre protegido.

Se corrige indicando secure messaging con un OR sobre el CLA real
(`apdu.instructionClass | 0x0c`), que es como lo describe ISO 7816-4, en
lugar de sustituirlo. Para `CLA=0x00` el resultado no cambia; para `CLA=0x90`
da `0x9C`. Sin confirmar todavía si `0x9C` es exactamente lo que el DNIe
espera para este comando en concreto —jmulticard nunca lo necesita: en
acceso por contacto lo envía sin ningún canal activo—, pero es la
generalización razonable de la convención que esta misma librería ya usa
para `CLA=0x00`.
