# Ingeniería inversa de Hackers de Trickster Arts
![GitHub](https://img.shields.io/github/license/Mario-jesus/ta-hackers-client)
[![Pruebas](https://github.com/Mario-jesus/ta-hackers-client/actions/workflows/tests.yml/badge.svg)](https://github.com/Mario-jesus/ta-hackers-client/actions/workflows/tests.yml)

## Descripción general
Esta herramienta proporciona un entorno de pruebas para investigar la API de red del juego móvil Hackers, desarrollado originalmente por Trickster Arts.

## Aviso de responsabilidad
Este proyecto tiene fines exclusivamente de investigación. Todo el código fuente se proporciona tal cual, sin garantías. No respaldo la explotación de vulnerabilidades ni el uso de trampas en este juego; actúas bajo tu propia responsabilidad.

## Entorno de pruebas
Utiliza mi gema [sandbox-ruby](https://github.com/animotto/sandbox-ruby).

El entorno de pruebas consta de los siguientes contextos:
- `chat` Chat interno
- `market` Compra de diversos objetos del juego
- `mission` Gestión de tus misiones
- `net` Mantenimiento de tu red
- `prog` Gestión de tus programas
- `query` Creación y análisis de consultas al servidor de la API
- `script` Ejecución de tus propios scripts para interactuar con el entorno de pruebas
- `top` Clasificación de jugadores
- `world` Mapa mundial

## Cómo ejecutarlo

Clona el repositorio en tu equipo y prepara el entorno:
```console
git clone https://github.com/Mario-jesus/ta-hackers-client.git
cd ta-hackers-client
# Usa Ruby 3.3.12 y Bundler 2.5.22.
export BUNDLE_PATH="$PWD/.bundle/native-readline"
export BUNDLE_APP_CONFIG="$PWD/.bundle"
export BUNDLE_FROZEN=true
bundle _2.5.22_ install
export RUBYLIB=$PWD/lib
```

Antes de usar el modo interactivo, [compila el callback nativo con GNU Readline 8.3](docs/cli-interactive-chat.md#reproducible-native-build-and-tests).
El artefacto nativo, excluido del control de versiones, no se distribuye mediante Git: vuelve a compilarlo después de actualizar
el código fuente nativo o cambiar Ruby o las herramientas de compilación. La ejecución por lotes o sin TTY no
carga este editor.

A continuación, [configura una cuenta](#configuración-de-la-cuenta) antes de conectarte.

## Configuración de la cuenta

Los archivos de configuración contienen JSON, aunque su extensión sea `.conf`.
`configs/default.conf` es la plantilla pública: su `id: 0` y su `password` vacío
son valores de ejemplo, no credenciales utilizables. La plataforma predeterminada es `apple`.
Conserva la configuración del servidor de la plantilla salvo que sepas que es necesario cambiarla.

### Crear una cuenta nueva

Para crear una cuenta nueva del juego y guardar automáticamente su ID y contraseña en
`configs/my.conf`, ejecuta lo siguiente desde la raíz del repositorio:

```bash
bundle exec ruby bin/sandbox -n my
chmod 600 configs/my.conf
```

Esto contacta con el servidor y crea una cuenta real; no lo uses simplemente para
abrir una cuenta existente. Copia la configuración predeterminada y rechaza sobrescribir
una configuración existente con el mismo nombre.

Como alternativa, el comando `new` del entorno de pruebas crea una cuenta y **muestra** su
ID, contraseña e ID de sesión:

```text
new
```

A diferencia de `-n my`, `new` no guarda una configuración ni cambia la sesión en curso
a la cuenta nueva. Guarda los valores devueltos de **ID y Password** en una configuración privada como
se describe a continuación y reinicia con esa configuración. El ID de sesión es temporal y
no sustituye esas credenciales.

### Vincular una cuenta existente con `cpuse`

Usa un código de cambio de plataforma perteneciente a una cuenta de tu propiedad. Un cliente ya
autenticado puede generar uno con `cpgen`. Trata el código como un secreto.
`cpuse` requiere una sesión conectada del entorno de pruebas; no puede ejecutarse con las credenciales
predeterminadas vacías.

Si todavía no tienes una cuenta que funcione en el entorno de pruebas, crea primero una temporal:

```bash
bundle exec ruby bin/sandbox -n bootstrap
chmod 600 configs/bootstrap.conf
bundle exec ruby bin/sandbox -a -m -c bootstrap
```

En la consola del entorno de pruebas, conéctate y canjea tu código para la plataforma de destino:

```text
connect
cpuse YOUR_PLATFORM_CHANGE_CODE apple
```

Sustituye `YOUR_PLATFORM_CHANGE_CODE` por tu código real. `cpuse` llama a la
API de cambio de plataforma y muestra los valores **ID y Password** de la cuenta vinculada; no
los escribe en disco ni reemplaza la sesión actual. Guarda esas credenciales devueltas
en una configuración independiente, en lugar de las credenciales de la cuenta temporal.
El argumento de plataforma debe coincidir con la configuración de destino.

### Guardar las credenciales y seleccionar la configuración

Por ejemplo, crea `configs/apple.conf` a partir de la plantilla pública **solo si ese
archivo aún no existe**:

```bash
cp -n configs/default.conf configs/apple.conf
chmod 600 configs/apple.conf
```

Edita `configs/apple.conf` con tu editor de texto preferido. Sustituye `id` y
`password` por los valores devueltos por `new` o `cpuse`, manteniendo un JSON válido:

```json
{
  "id": 123456789,
  "password": "REPLACE_WITH_RETURNED_PASSWORD",
  "platform": "apple"
}
```

Este es un fragmento, no un reemplazo de toda la plantilla: conserva el resto de sus
opciones. El ID anterior es solo un ejemplo; usa el ID numérico que hayas recibido. Deja
`autocmd` vacío si quieres conectarte manualmente.

Sal de la sesión anterior del entorno de pruebas e inicia una nueva con la configuración guardada:

```bash
bundle exec ruby bin/sandbox -a -m -c apple
```

Después, introduce `connect`. `-c apple` corresponde a `configs/apple.conf`; `-a` desactiva
los comandos automáticos de la configuración y `-m` utiliza la autenticación mínima.

**Mantén las credenciales en privado.** Nunca incluyas credenciales reales en el archivo versionado
`configs/default.conf`, en un README, en una incidencia ni en una captura de pantalla. Las configuraciones
privadas de las cuentas están excluidas de Git, pero las reglas de exclusión no protegen archivos que ya
están versionados; nunca fuerces la inclusión de archivos de credenciales.

## Instalación y ejecución en Termux (experimental)

Ejecuta estos comandos **dentro de Termux en Android**, no en tu equipo de escritorio. Mantén la
copia del repositorio dentro del directorio personal de Termux (`$HOME`), en lugar de usar almacenamiento compartido
como `/sdcard`. No se necesitan el lanzador `mise` de escritorio ni `env-ruby33.sh`.

**Compatibilidad:** el entorno de referencia utiliza Ruby 3.3.12 con GNU Readline 8.3.
Termux puede proporcionar una versión diferente de Ruby y estas instrucciones no se han
validado en Android. El editor interactivo sigue requiriendo GNU Readline 8.3;
no elimines su comprobación de versión para evitar un error de carga.

### 1. Instalar las herramientas del sistema y las dependencias de Ruby

```bash
pkg update
pkg upgrade
pkg install git ruby clang make pkg-config readline
gem install bundler --no-document
```

Si ya has clonado el repositorio en `~/ta-hackers-client`, entra directamente en ese directorio.
De lo contrario, clónalo primero:

```bash
git clone https://github.com/Mario-jesus/ta-hackers-client.git "$HOME/ta-hackers-client"
cd ~/ta-hackers-client
```

Desde la raíz del repositorio, instala las gemas:

```bash
unset BUNDLE_FROZEN BUNDLE_DEPLOYMENT
bundle update --bundler
bundle add base64 readline net-http
bundle install
```

Esto actualiza tus archivos locales `Gemfile` y `Gemfile.lock`: las versiones más recientes de Ruby pueden
haber dejado de proporcionar estas bibliotecas de forma implícita. Es un ajuste de configuración para Termux, no
la instalación con versiones fijadas del entorno de referencia descrita anteriormente.

### 2. Compilar y verificar el editor nativo de terminal

El artefacto nativo no está incluido en Git y debe compilarse en el teléfono. El
script auxiliar de compilación del proyecto requiere Ruby 3.3.12; para el entorno experimental de Termux,
configura y compila la extensión directamente en su directorio de compilación excluido de Git:

```bash
mkdir -p .bundle/native-readline-callback
cp ext/cli_readline_callback/extconf.rb \
   ext/cli_readline_callback/cli_readline_callback.c \
   .bundle/native-readline-callback/

(
  cd .bundle/native-readline-callback &&
  ruby extconf.rb --with-readline-dir="$PREFIX" &&
  make
)
```

Verifica el editor sin conectarte al juego:

```bash
bundle exec ruby -Ilib -rsandbox -rcli/interactive_shell \
  -e 'Sandbox::InteractiveShell.load_native; puts "Native editor OK"'
```

Continúa solo si se muestra `Native editor OK`. Si la compilación o la carga fallan,
conserva el error y comprueba `ruby -v` y la versión instalada de Readline antes de
continuar. Vuelve a compilar después de cambiar Ruby o actualizar el código fuente nativo. Una
carga correcta no demuestra la compatibilidad completa con el terminal de Android.

### 3. Iniciar con una cuenta existente

Para una configuración llamada `apple`, copia de forma segura el archivo de tu cuenta existente a
`configs/apple.conf` si todavía no está presente. Clonar el repositorio no
garantiza que tus credenciales privadas estén incluidas. No las publiques.
Si aún no tienes una configuración, sigue las instrucciones de [Configuración de la cuenta](#configuración-de-la-cuenta)
para crear una cuenta con `new` o vincular una con `cpuse` y guardar sus credenciales.

```bash
ls configs/apple.conf
chmod 600 configs/apple.conf
bundle exec ruby bin/sandbox -a -m -c apple
```

En la consola del entorno de pruebas, conéctate explícitamente:

```text
connect
```

`-a` desactiva los comandos automáticos de la configuración, `-m` selecciona la autenticación
mínima y `-c apple` carga `configs/apple.conf`. Esto utiliza la cuenta
existente; no crea una nueva. En los siguientes inicios, ejecuta el mismo
comando `bundle exec ruby bin/sandbox -a -m -c apple` desde la raíz del repositorio.

## Ciclo de sesión anti-AFK

Ejecuta `script run antiafk [online_minutes] [offline_minutes]` en un entorno de pruebas
autenticado. Ambos argumentos posicionales son opcionales:

```text
script run antiafk          # Predeterminado: 90 minutos conectado, 240–300 segundos aleatorios desconectado
script run antiafk 120      # 120 minutos conectado, 240–300 segundos aleatorios desconectado
script run antiafk 120 5    # 120 minutos conectado, 5 minutos fijos desconectado
```

Introduce únicamente minutos expresados como números enteros positivos, con un máximo de dos argumentos. Los valores
no válidos generan `Timing arguments must be positive whole-number minutes`; un exceso de
argumentos genera `Expected at most two timing arguments`. Ambos errores incluyen
`Usage: script run antiafk [online_minutes] [offline_minutes]` y detienen la ejecución antes de
adquirir el control exclusivo de la sesión o realizar solicitudes de autenticación, jugador o red.
Los mensajes de inicio y desconexión programada muestran el tiempo de conexión seleccionado;
el mensaje de silencio informa de su duración real en segundos.

Solo puede ejecutarse un trabajo anti-AFK
a la vez (incluidos los alias `./antiafk`). Usa `script jobs` para encontrar
su ID de trabajo y `script kill <id>` para detenerlo.

| Fase | Comportamiento local |
|------|----------------------|
| Conexión | Autenticación mínima seguida de la carga del jugador aproximadamente cada 60 segundos; un reloj monotónico mide cada ciclo de conexión (90 minutos de forma predeterminada). |
| Finalización de solicitudes y silencio | Rechaza las solicitudes nuevas en toda la herramienta, espera a que terminen las solicitudes admitidas, borra el ID de sesión local y permanece en silencio durante un periodo aleatorio de entre 240 y 300 segundos, ambos incluidos, o durante los minutos fijos de desconexión indicados. |
| Recuperación | Solo el propietario del trabajo anti-AFK puede enviar solicitudes de recuperación. Tanto la autenticación **como** la carga del jugador deben completarse correctamente antes de volver a permitir el resto del tráfico. Los errores de solicitud se reintentan indefinidamente tras 10, 20, 40, 80, 160 y después 180 segundos (límite máximo); una recuperación correcta reinicia el ciclo y la espera entre reintentos. |

Los demás scripts y las solicitudes interactivas fallan de inmediato con un
`Hackers::RequestError` que indica cómo proceder durante la finalización de solicitudes, el silencio y la recuperación; no se encolan
para volver a ejecutarse con sesiones obsoletas u operaciones de modificación. Un fallo de mantenimiento también inicia
una recuperación exclusiva sin posponer el plazo de silencio configurado originalmente (90 minutos de forma predeterminada).
Las esperas entre reintentos terminan al alcanzar ese plazo y pasan directamente al silencio programado
sin reabrir el tráfico. Una recuperación en curso que termina después del plazo
también pasa al silencio de inmediato; los reintentos posteriores al silencio vuelven a empezar en 10 segundos.
La autenticación que ya está en curso se deja terminar, incluido el análisis de la respuesta y las actualizaciones del estado
local, antes de iniciar el silencio, para que no pueda sobrescribir una sesión recuperada.

Cada línea del registro anti-AFK comienza con la fecha y hora locales del equipo y su desplazamiento
respecto a UTC, por ejemplo, `[2026-11-02 14:05:09 -03:00]`. Los registros identifican el inicio,
el mantenimiento autenticado, la desconexión programada, los intentos de reconexión,
la recuperación correcta y la siguiente espera entre reintentos (o la próxima pausa programada).
La etapa que ha fallado se muestra como `authentication` o `player load`.
`Anti-AFK starting` aparece inmediatamente después de que el trabajo asume el control;
`Anti-AFK activated successfully` confirma la activación solo después de que la autenticación
y la carga del jugador se completen correctamente. Ambos mensajes incluyen su propia marca de tiempo. Los fallos
al iniciar informan de su causa y de los reintentos sin confirmar falsamente la activación.

Los diagnósticos distinguen las evidencias observadas, sin adivinar por qué ha fallado una
sesión:

| Categoría del registro | Significado |
|------------------------|-------------|
| `Network/transport failure` | DNS, tiempo de espera agotado, conexión rechazada o restablecida, u otro error de transporte reconocido. |
| `TLS connection failed` | Falló TLS; esto no confirma un rechazo del servidor. |
| `Server rejected authentication (HTTP 401)` / `Server refused the request (HTTP 403)` | El servidor devolvió un rechazo HTTP explícito. |
| `Server rate limited the request (HTTP 429)` | El servidor limitó explícitamente la frecuencia de las solicitudes. |
| `Server returned an error (HTTP 5xx)` | Una respuesta de error del servidor, no una prueba de que otro jugador haya entrado en la red. |
| `Server reported a protocol rejection` | El juego devolvió una excepción de protocolo; no se infiere su causa subyacente. |
| `cause unconfirmed` | Los metadatos disponibles del error no bastan para clasificar la causa. |
| `Scheduled disconnection` | La pausa intencionada del ciclo configurado (90 minutos de forma predeterminada), no un fallo de red. |

No se registran las descripciones de las excepciones, los cuerpos de las respuestas, los ID de sesión ni las credenciales.
Las marcas de tiempo utilizan la hora del sistema para facilitar la lectura; la duración de los ciclos sigue midiéndose
con el reloj monotónico.

**Detener el trabajo cancela su control:** la limpieza libera el bloqueo del tráfico,
incluso durante la finalización de solicitudes, el silencio o la recuperación. Esto termina deliberadamente el silencio
programado antes de tiempo; una sesión borrada permanece borrada salvo que la recuperación se haya completado.
Si es necesario, vuelve a autenticarte antes de ejecutar comandos que dependan de la sesión.

Esto es una programación local del tráfico, no un endpoint de cierre de sesión ni una garantía frente a
la inactividad del lado del servidor, los ataques o la toma de control de la sesión. El servidor puede conservar una
sesión después de que comience el silencio local. Otros procesos, dispositivos y clientes quedan
fuera del control de esta herramienta. Las pruebas sin conexión no pueden demostrar la protección del lado del servidor.

## Contribuciones

Cualquier sugerencia es bienvenida; basta con abrir una incidencia en GitHub. Si quieres contribuir al código fuente, puedes crear una bifurcación de este repositorio y enviar una solicitud de cambios (pull request).

## Licencia
Consulta el archivo [LICENSE](LICENSE).
