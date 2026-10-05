# Informe técnico de ta-hackers

## Conclusión ejecutiva

**La hipótesis de que el proyecto pueda recuperarse mediante mantenimiento acotado es razonable, pero todavía no está demostrada.** El código y el historial muestran cambios incrementales de versión, constantes, cabeceras y parsers; no proporcionan evidencia de cómo funciona el backend actual.

El análisis permite establecer cuatro hechos importantes:

1. **Existe una capa de protocolo identificable y relativamente concentrada.** No habría que reconstruir necesariamente la consola y todos los modelos.
2. **Hay fallos internos del repositorio independientes del servidor**, incluidos métodos de la API que utilizan funciones eliminadas del serializador.
3. **El comando de conexión hace doce consultas antes de autenticar.** Un fallo percibido como “no inicia sesión” puede ocurrir antes del login.
4. **Los errores actuales no conservan bien la información HTTP.** Esto dificulta encontrar el primer punto de incompatibilidad y puede confundir un problema de transporte con uno de parsing.

### Alcance y límites

- Fecha del análisis: 4 de octubre de 2026.
- Estado del código revisado: commit local `aae76abe486f53bcf8367ce9b94463ee1f08493a`, del 28 de octubre de 2024.
- Fuentes: código, configuración, fixtures y historial Git local.
- No se contactó al backend ni se realizaron consultas DNS o búsquedas de issues remotos.
- No se instalaron dependencias ni se modificó el código durante el análisis.
- Las pruebas no pudieron ejecutarse porque el entorno no tenía Ruby ni Bundler disponibles.
- El informe describe el protocolo esperado por este cliente, no un protocolo actual verificado del juego.
- Las observaciones sobre otros jugadores y la actividad reciente del juego proceden del contexto aportado, no de comprobaciones independientes.

### Clasificación de evidencia

| Etiqueta | Significado |
|---|---|
| **[C] Confirmado por código** | Observado en la implementación revisada. |
| **[H] Confirmado por historial** | Observado en commits locales. |
| **[I] Inferencia fuerte** | Conclusión razonable derivada de la implementación. |
| **[?] Hipótesis** | Necesita evidencia actual o ejecución para comprobarse. |

Las referencias `archivo:líneas` corresponden al estado del código analizado y pueden desplazarse con cambios posteriores.

## A. Arquitectura real

**[C]** El proyecto es un cliente Ruby no oficial del juego móvil *Hackers*, de Trickster Arts, con biblioteca de dominio, consola y scripts. No es una herramienta general para atacar redes reales.

```text
bin/sandbox
    |
    +-- Configuración JSON
    +-- Datos locales de países
    +-- Consola interactiva
            |
            +-- Comandos: lib/cli/context/*
            +-- Scripts: scripts/*
                    |
                    v
              Hackers::Game
                    |
                    v
           Modelos / datasets
                    |
                    v
               Hackers::API
                    |
                    v
              Hackers::Client
                    |
                    v
             Backend del juego
```

**El serializador no es una etapa universal por la que pasa toda solicitud saliente.**

- Las solicitudes se construyen principalmente como parámetros de formulario.
- Algunos parámetros contienen estructuras serializadas específicas.
- Las respuestas se interpretan mediante `Serializer` y parsers propios de los datasets.

**Evidencia:** `README.md:5-9`; `bin/sandbox:117-151`; `lib/hackers/game.rb:17-54`; `lib/hackers/client.rb:45-105`; `lib/hackers/serializer.rb:36-53`.

## B. Flujo de una solicitud

### Solicitud normal con sesión

**[C]**

```text
Operación de Game o de un dataset
    v
Método de API
    v
Hash de parámetros: comando + argumentos + app_version
    v
Client#request_session: añade session_id
    v
Client#request_cmd: construye path?query y calcula cmd_id
    v
Añade cmd_id
    v
Client#request_raw: vuelve a codificar los parámetros
    v
Net::HTTP GET, o POST si existe data:
    v
Respuesta HTTP
    v
Control de estado HTTP
    v
Texto de respuesta
    v
Serializer / parser del dataset
    v
Objeto o modelo Ruby
```

**Evidencia:** `lib/hackers/client.rb:45-105`.

### Solicitudes sin sesión

Utilizan `request_cmd`, sin incorporar `session_id`. Entre ellas están autenticación y consultas de catálogos.

### Excepción con cuerpo POST

`API#finish_fight` proporciona un cuerpo con `replayString`. El transporte utiliza POST cuando `data` no está vacío.

**El cuerpo POST no participa en el hash de la URI.**

**Evidencia:** `lib/hackers/api.rb:558-580`; `lib/hackers/client.rb:65-73,95-105`.

## C. Host, ruta, transporte y versión

### Configuración del repositorio

**[C]**

| Elemento | Valor |
|---|---|
| Host | `hackers-1.appspot.com` |
| Puerto | `443` |
| TLS | Activado con la configuración predeterminada |
| Ruta | `/req.php` |
| Versión | `1227` |
| Constante del hash | `ZqQxXFFy` |
| Idioma | `en` |
| Plataforma | `google` |
| Compresión solicitada | Activada |

**Evidencia:** `configs/default.conf:2-12`; constantes en `lib/hackers/api.rb:7-14`.

El dominio es consistente con un despliegue en App Engine, pero **no demuestra la arquitectura interna actual del servidor**.

### Sobrescritura

`Game#initialize` permite trasladar a la API valores de configuración como host, puerto, ruta, constante, versión, idioma, plataforma y compresión.

**Evidencia:** `lib/hackers/game.rb:20-29`.

### Defecto de configuración TLS

El código utiliza:

```ruby
api_config[:ssl] = @config.key?('ssl')
```

**[C]** Comprueba la presencia de la clave, no su valor. Por tanto, `"ssl": false` no desactiva TLS si la clave sigue presente.

**Evidencia:** `lib/hackers/game.rb:23`.

Es un defecto local de configuración; **no prueba una incompatibilidad con el backend**.

### Cabeceras explícitas

```text
Content-Type: application/x-www-form-urlencoded
Accept-Charset: utf-8
User-Agent: BestHTTP/2 v2.2.0
Accept-Encoding: gzip, identity
```

Con compresión desactivada, la última pasa a `identity`.

**Evidencia:** `lib/hackers/client.rb:13-18,25-33`.

### Comportamiento HTTP

**[C]**

- GET por defecto.
- POST cuando existe un cuerpo `data`.
- Pool de cinco clientes con mutex.
- Conexiones reutilizadas mediante `client.start`.
- No hay seguimiento explícito de redirecciones.
- No hay gestión explícita de cookies.
- No se configuran tiempos de espera propios: se depende de la biblioteca.
- No hay reintentos automáticos en esta capa.
- Se acepta únicamente **HTTP 200**, no cualquier respuesta 2xx.

**Evidencia:** `lib/hackers/client.rb:25-40,65-90`.

## D. Autenticación

### Cuenta propia del juego

**[C]**

| Método Ruby | Comando del protocolo | Referencia |
|---|---|---|
| `create_player` | `player_create` | `lib/hackers/api.rb:136-143` |
| `auth` | `auth_id_password` | `lib/hackers/api.rb:190-199` |
| `auth_name` | `auth`, marcado como probablemente obsoleto | `lib/hackers/api.rb:1093-1102` |

El login por ID y contraseña incorpora `id_player` y `password` a los parámetros.

**No se envían mediante un POST de login:** el recorrido normal termina en GET, con las credenciales en la query, sobre TLS con los valores predeterminados.

**Evidencia:** `lib/hackers/api.rb:190-199`; `lib/hackers/client.rb:73`.

**Una URL de autenticación registrada sin censurar puede exponer la contraseña.** Las configuraciones de cuenta también deben tratarse como datos sensibles: su persistencia es JSON en texto plano, no una base de datos cifrada.

**Evidencia de persistencia:** `lib/cli/sandbox.rb:10-31`; `bin/sandbox:70-87`.

### Google y Facebook

Hay wrappers para `auth_google_new`, `auth_fb` y operaciones de vinculación.

**[C]** La conexión ordinaria de la consola utiliza el login de cuenta propia; no depende de esos proveedores.

**Evidencia:** `lib/hackers/api.rb:178-199,1147-1155,1295-1332`; `lib/cli/context/root.rb:163`.

Una incompatibilidad de autenticación externa debe investigarse por separado.

### El login no es el primer paso

`connect` carga, en este orden:

1. Traducciones.
2. Configuración del juego.
3. Tipos de nodos.
4. Tipos de programas.
5. Misiones.
6. Skins.
7. Hints.
8. Experiencia.
9. Builders.
10. Goals.
11. Shields.
12. Ranks.
13. **Autenticación.**

**[C] El primer punto de fallo posible es `language_translations.load`, no `Game#auth`.**

**Evidencia:** `lib/cli/context/root.rb:110-167`.

## E. Sesión

**[C]** `Game#auth` interpreta la respuesta y toma el identificador de sesión de:

```text
sección 0 -> registro 0 -> campo 3
```

Lo almacena en `@api.sid`.

**Evidencia:** `lib/hackers/game.rb:64-75`.

Posteriormente, `Client#request_session` añade `session_id=<valor>` **antes de calcular el hash**.

**Evidencia:** `lib/hackers/client.rb:103-105`.

### Limitaciones

- La sesión se mantiene en memoria.
- No hay lógica explícita de expiración o renovación.
- `connected?` delega en `sid?`.
- `sid?` comprueba únicamente que el valor no sea `nil`.
- Incluso una cadena vacía puede considerarse una sesión existente.

**Evidencia:** `lib/hackers/game.rb:56-60`; `lib/hackers/api.rb:62-64`.

**[I] “Connected” significa que existe un valor de sesión, no que el servidor lo siga aceptando.**

## F. Hash exacto de las solicitudes

### Entrada

**[C]** Se calcula sobre:

```text
ruta + "?" + URI.encode_www_form(parámetros)
```

No se incluye el host, el puerto ni el esquema HTTPS.

**Evidencia:** `Client#generate_uri_raw`, `lib/hackers/client.rb:45-47`.

### Fórmula

```text
U = ruta + "?" + query codificada

posición = mínimo(longitud de U, 10)

S = U con la constante insertada en esa posición

D = MD5(S), resultado binario de 16 bytes

T = bytes de D en índices 2..7
    -> seis bytes

B = Base64 estricto de T
    -> ocho caracteres

cmd_id = B con:
         "=" sustituido por "."
         "+" sustituido por "-"
         "/" sustituido por "_"
```

**Evidencia:** `Client#hash_uri`, `lib/hackers/client.rb:112-120`.

Para seis bytes, Base64 no necesita padding; la sustitución de `=` está implementada, aunque normalmente no afecta a ese resultado.

### Orden

```text
parámetros de la operación
    -> session_id, si corresponde
    -> hash
    -> cmd_id
```

El código no ordena alfabéticamente los parámetros: utiliza el orden de construcción de la estructura.

**Evidencia:** `lib/hackers/client.rb:95-105`.

### Dependencias

| Dato | ¿Participa? |
|---|---|
| Ruta | Sí |
| Comando | Sí |
| Parámetros de la query | Sí |
| `app_version` | Sí, al estar en la query |
| `session_id` | Sí, cuando se incorpora |
| ID y contraseña del login | Sí, porque son parámetros de esa solicitud |
| Host y HTTPS | No |
| Cuerpo POST | No |
| Timestamp o nonce automático del cliente | No se añade en estas funciones |

**No es una firma con una clave privada ni un MAC basado en un secreto de usuario:** es un tag calculado con una constante pública y MD5 truncado.

Lo confirmado es **cómo lo genera el cliente antiguo**, no cómo lo valida el servidor actual.

## G. Serialización

### Estructura principal

**[C]**

| Delimitador | Nivel |
|---|---|
| `@` | Secciones |
| `;` | Registros dentro de una sección |
| `,` | Campos dentro de un registro |

La representación principal es `datos[sección][registro][campo]`.

**Evidencia:** `lib/hackers/serializer.rb:5-16,36-53,115-125`.

El ejemplo conceptual `A,B;C,D@E,F` se interpreta como dos secciones, con dos registros en la primera y uno en la segunda.

### Caracteres especiales

| Carácter literal | Carácter de sustitución |
|---|---|
| `@` | `\x03` |
| `;` | `\x02` |
| `,` | `\x01` |

**Evidencia:** `Serializer.normalizeData`, `lib/hackers/serializer.rb:20-32`; `Base#normalize/#denormalize`, `127-155`.

**No conviene sustituir esos caracteres antes de separar toda la respuesta:** podría convertir un delimitador literal dentro de un texto en un separador estructural.

### Tipos de datos

No hay un esquema general equivalente a JSON:

- Los campos se obtienen inicialmente como texto.
- Los modelos convierten campos concretos con `.to_i`.
- Los nombres de propiedades se asignan por posición.
- No se define un marcador universal de `null`.
- No hay una conversión universal de booleanos.
- Fechas y tiempos no reciben un tipo universal en el serializador.

**Evidencia:** `lib/hackers/serializer.rb:36-53,216-231,247-257,316-323`.

### Campos vacíos

El código utiliza `String#split` sin un límite explícito. Esto introduce fragilidad respecto a campos vacíos finales. Esa semántica debe incluirse en pruebas de compatibilidad; **no fue comprobada mediante ejecución en este entorno**.

### Otros formatos internos

- Readme utiliza `\x04`: `lib/hackers/serializer.rb:178-195`.
- Topología y otras estructuras tienen generadores específicos: `lib/hackers/dataset/network.rb:210-234`.
- Los enlaces de simulación/replay tienen un esquema separado de XOR y comprobaciones de integridad: `lib/hackers/link.rb:23-189`.

Los enlaces utilizan `link.hackersthegame.com`, distinto del host de la API; su codificación no debe confundirse con el hash de `/req.php`.

**Evidencia:** `lib/hackers/link.rb:9-10`; `lib/hackers/api.rb:7`.

### Compresión: incertidumbre importante

**[C]** El proyecto solicita gzip, pero no contiene una descompresión explícita antes de interpretar el cuerpo:

```ruby
body = response.body.force_encoding('UTF-8')
```

**Evidencia:** `lib/hackers/client.rb:31-33,78`.

Cambiar la etiqueta de codificación **no descomprime**.

No se pudo confirmar con ejecución ni con documentación específica recuperada el comportamiento exacto de `Net::HTTP` para esa cabecera y la versión de Ruby utilizada.

**[?] Si llegan bytes gzip sin descompresión automática, el parsing fallará. No está demostrado que eso esté ocurriendo actualmente.**

## H. Mapa de comandos

**[C]** Se identificaron **101 llamadas en `lib/hackers/api.rb`**:

- **22** mediante `request_cmd`.
- **79** mediante `request_session`.

Esto no significa 101 rutas HTTP. Son operaciones multiplexadas sobre `/req.php`.

### Comandos principales

| Área | Comandos reales representativos | Referencia en `lib/hackers/api.rb` |
|---|---|---|
| Catálogos | `i18n_translations_get_language`, `app_setting_get_list`, `get_node_types_and_levels`, `get_program_types_and_levels`, `missions_get_list` | `68-120` |
| Conectividad | `check_connectivity` | `124` |
| Cuenta | `player_create`, `auth_id_password` | `136-199` |
| Red | `net_get_for_maintenance`, `net_update`, `create_node_and_update_net`, `node_delete_net_update` | `203-255` |
| Nodos | `upgrade_node`, `finish_node`, `collect`, `node_set_builders` | `260-324` |
| Programas | `create_program`, `upgrade_program`, `finish_program`, `program_delete`, `queue_sync_new` | `328-393` |
| Mundo | `player_get_world`, `player_get_new_targets`, `bonus_collect` | `412-450` |
| Objetivos | `goal_update`, `goal_reject` | `452-475` |
| Chat | `chat_display`, `chat_send` | `479-505` |
| Repeticiones | `fight_get_replay`, `fight_get_replay_info` | `613-638` |
| Perfil | `player_get_info`, `get_net_details_world` | `655-678` |
| Mercado | `player_buy_skin`, `shield_buy`, `player_buy_currency_percentage` | `738-789` |
| Ranking | `ranking_get_all` | `792` |
| Misiones | `player_missions_get_log`, `player_mission_message_delivered`, `player_mission_reject`, `player_mission_update` | `806,1106,1252,1431` |

### Advertencias de obsolescencia

El autor deja notas sobre operaciones como:

- `player_set_name`: probablemente deshabilitada.
- `auth` por nombre: probablemente obsoleta.
- `fight_by_player`: no descrita como solicitud pública.

**Evidencia:** `lib/hackers/api.rb:146-159,1091-1102,1263-1277`.

Son advertencias del código, **no comprobaciones del servidor actual**.

## I. Modelos y parsers

### Ejemplo: perfil

**[C]** `Serializer::Profile#parse` interpreta:

| Índice | Campo |
|---:|---|
| 0 | ID |
| 1 | Nombre |
| 2 | Dinero |
| 3 | Bitcoins |
| 4 | Créditos |
| 5 | Experiencia |
| 9 | Rango |
| 10 | Builders |
| 11-12 | Coordenadas |
| 13 | País |
| 14 | Skin |

**Evidencia:** `lib/hackers/serializer.rb:200-231`.

**[I]** Los saltos y offsets rígidos hacen plausible que un cambio pequeño de esquema produzca datos incorrectos sin cambiar el transporte ni los comandos.

### Fallos internos de la API

Se encontraron ocho métodos que dependen de funciones ausentes del serializador:

| Método | Fallo local | Momento |
|---|---|---|
| `queue_sync_finish` | `Serializer.generatePrograms` ausente | Antes del envío |
| `set_readme_fight` | `Serializer.generateReadme` ausente | Antes del envío |
| `attack_net` | `Serializer.new`, siendo un módulo | Después de recibir respuesta |
| `replay` | Igual | Después de recibir respuesta |
| `replay_info` | Igual | Después de recibir respuesta |
| `map_fight` | Igual | Después de recibir respuesta |
| `revive_ai_finish` | Igual | Después de recibir respuesta |
| `finish_revive_ai` | Igual | Después de recibir respuesta |

**Evidencia:** `lib/hackers/api.rb:397-407,833-843,509-519,613-636,949-957,1378-1401`; definición de `Serializer` en `lib/hackers/serializer.rb:1-2`.

Una operación puede obtener respuesta del servidor y fallar después en Ruby. **El mensaje final por sí solo no demostraría incompatibilidad del protocolo.**

No se encontraron consumidores actuales de esos ocho métodos en los puntos de entrada revisados; son callejones sin salida latentes de la biblioteca.

## J. Scripts

### `scripts/autohack.rb`

**[C]**

- Variable `k` sin definir: línea 25.
- Comas faltantes en un hash: líneas 58-64.
- Métodos antiguos `cmdNetGetForAttack`, `cmdFightUpdate`, `cmdFight`, `cmdNetLeave`: líneas 29, 32, 53 y 70.
- Referencias a constantes antiguas de `Game`.

La comprobación sintáctica con Ruby quedó pendiente por falta del ejecutable, pero las inconsistencias son visibles en el texto.

### Otros scripts

- `scripts/replay.rb:12` llama a `cmdFightGetReplay`.
- `scripts/replayinfo.rb:15` llama a `cmdFightGetReplayInfo`.
- Telegram utiliza referencias que no coinciden con la API de `Game` revisada.

**Conclusión:** estos problemas pertenecen a mantenimiento interno de scripts y wrappers. **No deben utilizarse como evidencia de que el backend cambió.**

## K. Tests

### Cobertura existente

**[C]**

| Spec | Qué comprueba |
|---|---|
| `spec/client_spec.rb` | Hashes de URI |
| `spec/link_spec.rb` | Enlaces válidos e inválidos |
| `spec/node_types_spec.rb` | Parsing de tipos de nodos |
| `spec/program_types_spec.rb` | Parsing de tipos de programas |

**Evidencia:** `spec/client_spec.rb:10-26`; `spec/link_spec.rb:14-52`; `spec/node_types_spec.rb:8-15`; `spec/program_types_spec.rb:8-15`.

Las rutas de prueba revisadas son **locales**: crean objetos, procesan fixtures y comparan resultados, sin iniciar conexiones HTTP.

No cubren de extremo a extremo autenticación, transporte HTTP, consola ni automatizaciones.

### Resultado observado

| Comprobación | Resultado |
|---|---|
| `ruby --version` | No disponible |
| `bundle --version` | No disponible |
| `bundle exec rspec` | No ejecutado |
| `ruby -c scripts/autohack.rb` | No ejecutado |

**No hay pruebas confirmadas como aprobadas o fallidas en esta revisión.**

La CI declara Ruby 2.7 y ejecuta `bundle exec rspec`: `.github/workflows/tests.yml`.

## L. Dumps y fixtures

### Corrección respecto al análisis inicial

**El directorio `dumps/` no contiene capturas suministradas por el repositorio.** Solo contiene su `.gitignore`.

La consola permite exportar/importar dumps, pero eso no significa que existan muestras versionadas.

**Evidencia:** `dumps/.gitignore`; `lib/cli/context/query.rb:264`.

### Material disponible

Los nombres de fixtures de esta tabla son relativos a `spec/data/`.

| Fixture | Consumidor | Utilidad |
|---|---|---|
| `config.yml` + `hash_uri.yml` | `client_spec.rb` -> `Client#hash_uri` | Validar fórmula con siete vectores |
| `node_types.yml` | `node_types_spec.rb` -> parser de nodos | Payload Base64 y expectativas |
| `program_types.yml` | `program_types_spec.rb` -> parser de programas | Payload Base64 y expectativas |
| `simlinks.yml` | `link_spec.rb` -> parser de enlaces | Simulaciones |
| `replaylinks.yml` | `link_spec.rb` -> parser de enlaces | Repeticiones |
| `invalid_links.yml`, `invalid_uri.yml` | `link_spec.rb` | Validación negativa |

**Evidencia:** referencias de fixtures en `spec/client_spec.rb:7-25`, `spec/link_spec.rb:6-49`, `spec/node_types_spec.rb:6-9`, `spec/program_types_spec.rb:6-9`.

Los vectores de hash utilizan **versión 1220 y constante `WGmHVNph`**, no los valores predeterminados revisados.

No hay metadatos suficientes para afirmar fechas o procedencia exacta de las respuestas de nodos/programas. El mapa disponible es **fixture -> prueba -> parser**, no un corpus completo **comando -> captura fechada -> modelo**.

## M. Cambios históricos importantes

**[H]**

| Commit | Cambio observado | Qué permite concluir |
|---|---|---|
| `2135c10` | Estado inicial con versión 1208 y constante `Thae9aeP` | Existía otro par de valores |
| `e37e8f8` | Versión 1210 y constante `WGmHVNph` | Hubo cambio conjunto |
| `3946eb4` | Versión 1220 | No toda actualización rotó la constante |
| `46923f2` | Versión 1224 y constante `ZqQxXFFy` | Segunda rotación observada |
| `49e68e8` | UA `UniWeb` -> `BestHTTP/2 v2.2.0`; cambios de compresión anunciada | Las cabeceras se adaptaron |
| `3767236` | Refactorización del serializador | Explica referencias locales antiguas |
| `dbe8cec` | Reutilización de conexiones | Evolución del transporte |
| `ff394e2` | Nuevo manejo de excepciones | Evolución de interpretación de errores |
| `29038c6` | Versión 1227 en configuración y API | Confirma el commit mencionado |
| `aa47026` | Compresión opcional en configuración, API, cliente y Game | Confirma el commit mencionado |
| `aae76ab` | Corrección de interpretación de estado en logs | Hubo mantenimiento de parsing posicional |

**La historia apoya una evolución incremental del cliente. No demuestra que la siguiente reparación también sea pequeña.**

Tampoco hay evidencia de “caducidad automática” de la constante. Lo observado son cambios explícitos del autor.

No se encontró documentación concluyente sobre las herramientas originales de descubrimiento. No se revisaron issues remotos ni las fotografías en esta etapa. No se atribuye el protocolo a Metasploit, Wireshark, Burp, mitmproxy o análisis del APK.

## N. Componentes reutilizables

**[I]** Hay reutilización potencial clara, condicionada a que el protocolo conserve parte de su estructura:

- Consola y organización por contextos.
- Impresión de datos.
- Configuración.
- Ejecución de scripts.
- Abstracciones de jugador, nodos, programas y misiones.
- Infraestructura de transporte.
- Parsers y fixtures que sigan coincidiendo con las respuestas.
- Herramientas de inspección del contexto `query`.

**No se consideran “seguramente reutilizables” los parsers posicionales:** son precisamente una de las zonas que necesita contrastarse.

**Evidencia:** `lib/cli/context/*`; `lib/hackers/game.rb:17-54`; `lib/hackers/dataset/*`; `lib/hackers/client.rb:25-105`.

## O. Componentes obsoletos o frágiles

### Confirmadamente inconsistentes dentro del repositorio

- Los ocho métodos con referencias antiguas a `Serializer`.
- Scripts con métodos y constantes eliminados.
- Configuración TLS basada en presencia de clave.
- Diagnóstico HTTP que descarta el estado original.

### Candidatos a obsolescencia externa, todavía no confirmados

- `app_version=1227`.
- Constante `ZqQxXFFy`.
- Host/ruta.
- User-Agent.
- Autenticación.
- Posiciones de campos.
- Requisitos de compresión.
- Comandos marcados como posiblemente deshabilitados.

**Separar estas categorías evita reparar el problema equivocado.** Las referencias concretas de cada categoría están en las secciones C-I.

## P. Ranking de posibles incompatibilidades

Este ranking expresa **prioridad diagnóstica**, no probabilidades medidas ni causas actuales confirmadas.

| Prioridad | Candidato | Evidencia y prueba pendiente |
|---:|---|---|
| 1 | Versión y constante del hash | Cambiaron históricamente. Comparar con evidencia actual, sin asumir que deban cambiar juntas. |
| 2 | Compresión y tratamiento del cuerpo | Se anuncia gzip y no hay descompresión explícita. Validar primero con servidor local. |
| 3 | Primera consulta previa al login | Traducciones o catálogos pueden impedir llegar a `auth`. Identificar la operación exacta que falla. |
| 4 | Host, ruta, redirección o TLS | Son supuestos configurados; el cliente no sigue redirecciones. Necesitan evidencia actual. |
| 5 | Parámetros obligatorios o codificación/orden | El hash depende de la representación exacta de la query. Comparar solicitudes. |
| 6 | Cambio del login o sesión | Parsing rígido en `[0][0][3]`, sin renovación. Comparar respuesta de autenticación. |
| 7 | Desplazamiento de campos | Parsers posicionales y correcciones históricas. Comparar esquemas por comando. |
| 8 | Validación adicional del cliente | UA antiguo y posibles requisitos nuevos. No hay evidencia local de attestation o WAF. |
| 9 | Retirada de comandos concretos | Afectaría funcionalidades específicas; no necesariamente al cliente completo. |

**Evidencia base:** `configs/default.conf:2-12`; `lib/hackers/client.rb:45-120`; `lib/cli/context/root.rb:110-167`; `lib/hackers/game.rb:64-75`; `lib/hackers/serializer.rb:216-231`; historial de la sección M.

## Q. Plan de diagnóstico

### Etapa 1: separar fallos locales

Cuando se autorice disponer de un entorno Ruby:

1. Ejecutar los cuatro specs existentes.
2. Comprobar sintaxis de scripts sin ejecutarlos.
3. Comprobar los métodos de API con referencias antiguas.
4. Validar serialización de campos vacíos y caracteres especiales.
5. Usar un servidor **local** para comprobar GET/POST, compresión y respuestas de error.

Esto no necesita contactar al juego.

### Etapa 2: obtener evidencia del primer fallo

Antes de probar el backend, recopilar de cualquier ejecución actual autorizada:

```text
operación que falla
fase: construcción / transporte / HTTP / parsing / modelo
versión y opciones relevantes
estado HTTP
Content-Type y Content-Encoding
cuerpo censurado
clase y mensaje de excepción
```

No conservar contraseñas, sesiones ni URLs de login sin censurar.

### Por qué hay que mejorar la observación

**[C]** `RequestError` conserva `type` y `description`, pero no el código HTTP.

Además:

- Un cuerpo de error vacío puede producir `Serializer::ParserError`.
- Un cuerpo HTML puede interpretarse como texto del supuesto error del juego.
- HTTP 201 o 204 entra en la rama de fallo.
- HTTP 200 se devuelve sin un detector genérico de errores semánticos.

**Evidencia:** `lib/hackers/client.rb:78-90,125-144`; `lib/hackers/serializer.rb:77-95,164-172`.

**403 no prueba firma incorrecta; 404 no prueba por sí solo ruta retirada; 200 no prueba éxito funcional.**

### Etapa 3: comparación actual, solo con autorización posterior

```text
conexión
    -> respuesta HTTP
    -> consulta pública simple
    -> formato de respuesta
    -> autenticación
    -> sesión
    -> consulta de solo lectura
    -> modelos
    -> CLI
    -> scripts
```

No comenzar con automatizaciones, compras u operaciones que modifiquen cuentas. Tampoco probar constantes al azar: primero buscar una diferencia respaldada por evidencia.

## R. Estimación de superficie de mantenimiento

No hay base suficiente para dar horas fiables. Sí para delimitar escenarios.

| Escenario | Superficie probable |
|---|---|
| Solo versión/constante/configuración | `configs/default.conf`, constantes de `lib/hackers/api.rb` y nuevos vectores de prueba |
| Transporte, cabeceras o compresión | `lib/hackers/client.rb`, configuración y pruebas HTTP locales |
| Login o sesión | Métodos de autenticación en `lib/hackers/api.rb`, `lib/hackers/game.rb`, fixtures de respuestas |
| Esquema de algunas respuestas | `lib/hackers/serializer.rb` y datasets afectados |
| Protocolo completo distinto | Sustitución sustancial de transporte/API/serialización; reutilización parcial de dominio y consola |
| Scripts viejos | Reparación separada de `scripts/*`, una vez comprobado el cliente base |

**Un cambio de host o ruta por sí solo no justifica una reescritura.** Son valores configurables.

Tampoco una firma nueva obliga necesariamente a reemplazar todos los modelos: depende de si las respuestas y operaciones mantienen su estructura.

## Ficha reconstruida del protocolo antiguo

```text
Backend predeterminado:
  hackers-1.appspot.com

Transporte:
  HTTPS, puerto 443

Ruta:
  /req.php

Método:
  GET normalmente
  POST cuando hay data:, como replayString

Versión:
  1227, enviada como app_version

Comando:
  Clave de operación dentro de la query

Codificación de parámetros:
  URI.encode_www_form

Sesión:
  session_id añadido antes de calcular cmd_id

Hash:
  path?query
    -> insertar constante pública en posición min(longitud, 10)
    -> MD5 binario
    -> bytes 2..7
    -> Base64 estricto
    -> sustituir "=" por ".", "+" por "-", "/" por "_"
    -> cmd_id añadido a la query

Login:
  auth_id_password
  id_player y password en parámetros

Respuesta:
  Texto interpretado mediante secciones, registros y campos

Delimitadores:
  @ -> secciones
  ; -> registros
  , -> campos

Escapes:
  \x03, \x02, \x01 para delimitadores literales

Modelo:
  Interpretación posicional y conversiones específicas

Errores:
  Solo HTTP 200 aceptado
  Otros estados se interpretan mediante Serializer::Exception
  El estado HTTP original no se conserva en RequestError
```

## Dictamen final

**No hay evidencia que justifique reconstruir todo desde cero. Tampoco hay evidencia suficiente para asegurar que cambiar `1227` resolvería el problema.**

Esta revisión separa dos líneas:

1. **Inconsistencias internas confirmadas**, reparables sin conocer el backend actual.
2. **Supuestos externos pendientes de comparación**, como versión, hash, transporte, autenticación y esquemas.

El siguiente paso con mayor valor es **identificar la primera operación y la primera capa que fallan, conservando su respuesta original de forma censurada**. A partir de esa evidencia se podrá decidir si el mantenimiento es pequeño, medio o una reconstrucción parcial, sin confundir scripts abandonados con cambios del protocolo.

## Seguimiento — 2026-10-04 (T1/T3/T4: transporte HTTP, diagnóstico acotado y consolidación)

Este apartado es un seguimiento fechado; la revisión anterior se conserva como instantánea histórica sin modificaciones. Corresponde a las tareas T1, T3 y T4 (`odd/tasks/http-compatibility-diagnostics.md`) sobre la rama `fix/http-compatibility-diagnostics`. El escritor trabajó offline (sin peticiones al backend y sin ejecutar los APK); el diagnóstico de backend de T3 fue realizado por un actor externo de solo lectura y se registra aquí como evidencia separada.

### Línea base y alcance verificado

| Elemento | Resultado |
|---|---|
| Línea base | 669 ejemplos offline, 0 fallos (Ruby 3.3.12, Bundler 2.6.9) |
| Nuevas pruebas | 26 ejemplos loopback en `spec/client_http_spec.rb` (127.0.0.1, puertos efímeros, sin DNS ni backend) |
| Ciclo TDD inicial (T1) | RED observado antes de implementar: `22 ejemplos, 14 fallos`; después de implementar: `22 ejemplos, 0 fallos` |
| Corrección tras verificación independiente | RED observado antes de corregir: `26 ejemplos, 5 fallos`; después de corregir: `26 ejemplos, 0 fallos` |
| Suite completa final | 695 ejemplos, 0 fallos (`bundle exec rspec --format progress`) |
| Verificación independiente previa (T2 runtime) | 691 ejemplos, 0 fallos; sintaxis y `git diff --check` limpios; suite de hash sin cambios |
| Verificaciones finales | `ruby -c` correcto en `lib/hackers/client.rb` y `spec/client_http_spec.rb`; `git diff --check` limpio |
| Comando de prueba | `source ~/.local/share/ta-hackers-toolchain/env-ruby33.sh && ~/.local/bin/mise exec ruby@3.3.12 -- ruby "$GEM_HOME/bin/bundle" _2.6.9_ exec rspec spec/client_http_spec.rb` |

### Comportamientos nuevos observados

- **Gzip:** las respuestas 200 con `Content-Encoding: gzip` se descomprimen una sola vez mediante `Zlib::GzipReader`/`StringIO` (stdlib, sin gemas nuevas). Se verificó empíricamente en Ruby 3.3.12 que `Net::HTTP` descomprime de forma transparente y elimina la cabecera cuando la petición no declara `Accept-Encoding`, y que conserva la cabecera `gzip` y el cuerpo comprimido cuando la petición la declara (caso del cliente). La implementación decide por la cabecera de la respuesta: si desapareció (decodificación transparente) no hay segunda descompresión; si está presente, se descomprime una vez.
- **Gzip malformado o truncado:** ya no se devuelven bytes corruptos como si fueran éxito; se lanza `RequestError` con evidencia segura (estado HTTP, tipo de contenido, codificación, bytes) y una razón acotada e imprimible, sin eco del cuerpo.
- **Errores HTTP no 200 (contrato endurecido):** el estado deja de descartarse. `RequestError` expone ahora `http_status`, `content_type`, `content_encoding` y `byte_count` como lectores opcionales; el constructor posicional `(type, description)` y el formato de mensaje (`to_s`) se mantienen intactos para compatibilidad.
- **Sin eco de cuerpos arbitrarios:** solo el mapeo de excepciones conocidas puede reflejar el tipo reconocido y la descripción incluida en la lista blanca de `EXCEPTIONS` (con el tipo literal `Exception`). Cualquier otro cuerpo — vacío, HTML, binario, UTF-8 inválido o sobre no reconocido — produce una razón estática sin cuerpo ("empty response body", "unexpected response body", "redirection response (not followed)") junto con la evidencia de cabeceras/bytes. Los datos no mapeados (p. ej. `Exception,secretvalue`) no se almacenan ni se ecoan en mensajes; solo se retiene el tipo literal `Exception` con descripción omitida. Ya no se filtran `Serializer::ParserError`, `ArgumentError` de codificación ni texto del cuerpo.
- **Evidencia de cabeceras acotada:** `content_type` y `content_encoding` se reportan solo si son ASCII imprimibles y se truncan a 256 caracteres; en otro caso se omiten (`nil`). No se incluyen otras cabeceras ni fragmentos de cuerpo, y la razón de "unsupported content encoding" ya no repite el valor de la cabecera.
- **Mapeo de excepciones conocidas:** intacto. `Exception,maximum node level reached`, `Exception,too many builders requested` y `Exception,mission already finished` siguen produciendo sus excepciones mapeadas con el mismo mensaje `to_s`, ahora además con `http_status`. Sin seguimiento de redirecciones ni aceptación de 201: el contrato de éxito exacto en HTTP 200 no cambia. No se alteraron tiempos de espera, reintentos, proxy ni TLS, y no se conecta automáticamente.

### Diagnóstico acotado del backend (T3) — actor externo de solo lectura

Se realizaron exactamente 2 peticiones GET HTTPS anónimas y directas a `hackers-1.appspot.com:443/req.php` (parámetros en orden comando/`app_version`/`cmd_id`, sal y hash existentes, `TLS_VERIFY_PEER`, tiempos de espera 10/15/10, `max_retries` 0, ~1 s de separación, sin auth/sesión/cookie, sin redirecciones, sin riesgo de estado):

| Elemento | Versión 1227 | Versión 1229 (hipótesis) |
|---|---|---|
| Respuesta | HTTP 200, `text/html;charset=UTF-8`, `Content-Encoding: gzip`, 27 bytes en crudo | idéntica forma |
| Cuerpo decodificado | 1 byte `1` | 1 byte `1` |
| Tiempo aproximado | 5,73 s (primera petición) | 0,33 s (segunda petición) |

Precauciones de esta evidencia:

- **Confirmado:** el servidor devuelve actualmente gzip para la cabecera anunciada; la corrección de T1 era necesaria.
- **No afirmado:** la validez de la sal/hash, la legitimidad del `app_version` 1229 actual o el funcionamiento del login; el comando de comprobación puede validar de forma laxa y no demuestra compatibilidad de autenticación ni del protocolo completo.
- Sin cambios de configuración ni de la versión por defecto (1227 sigue en `configs/default.conf`).

### Inventario APK verificado — evidencia y límites

| APK | SHA-256 | Tamaño (bytes) | versionCode | Contenido relevante |
|---|---|---|---|---|
| 1.224 | `80474faab608728d6ed653b0a2a1f4ab9719461c57f4082473125b26e3da6a5a` | 119 092 896 | 122401 | `global-metadata.dat`; `libil2cpp.so` en arm64-v8a y armeabi-v7a |
| 1.227 | `a0e384b2c0e48910c4ca230d5f47228358b867f6a1e5e1d38100c8d886c38c7b` | 90 180 658 | 122700 | `global-metadata.dat`; sin `lib/*.so` |
| 1.229 | `2afc7e829be910003bb636f7bed90b0d50cf3593a15744354c2e73869e11dbd8` | 90 532 222 | 122903 | `global-metadata.dat`; sin `lib/*.so` |

Límites de esta evidencia:

- Los metadatos de los tres APK contienen las cadenas literales del host/ruta, la sal pública (`ZqQxXFFy`), `app_version`, `cmd_id` y comandos; la mera presencia de cadenas **no** demuestra equivalencia del algoritmo activo de hash ni del protocolo actual.
- Los `versionCode` (122401/122700/122903) y los nombres de visualización (1.224/1.227/1.229) provienen de AXML estático.
- Para seguir el algoritmo real de 1.229 y su `app_version` activo se necesitan los splits nativos correspondientes (p. ej. `split_config.arm64_v8a.apk`) o un archivo completo APKM/XAPK; sin ellos no hay `lib/*.so` verificable en 1.227/1.229.
- No se ejecutó código de las aplicaciones, no se subieron APKs y no se certifica la autenticidad de las firmas. No se incluyen afirmaciones inventadas (prueba de sal, funciones nativas nulas, versión de Unity).

### Pendientes

- **T2 — revisión nativa:** pendiente de consentimiento explícito del usuario; la verificación runtime independiente (691 ejemplos, 0 fallos) ya está registrada y el escritor autocorrigió y revalidó (695 ejemplos, 0 fallos).
- Sin commits ni PR: no se ha solicitado ninguna entrega remota. Próxima acción: evaluación/revisión nativa del candidato.
