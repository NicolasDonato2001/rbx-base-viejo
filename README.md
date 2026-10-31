# rbx-base

Base reutilizable para juegos de Roblox, agnóstica de género. No es un juego:
es el andamiaje que todo juego necesita igual, ya listo y verificado, para no
reescribirlo en cada proyecto.

Construida con [Rojo](https://rojo.space): el código vive en archivos, no
dentro del `.rbxl`.

## Arrancar

```bash
rokit install      # instala rojo, wally, selene y stylua en las versiones pinneadas
wally install      # opcional: solo si vas a usar los paquetes de wally.toml
rojo serve         # y conectar desde el plugin de Rojo en Studio
```

El proyecto corre sin `wally install`: los sistemas core no dependen de ningún
paquete externo a propósito, así un clon nuevo arranca de una.

## Qué trae

### Persistencia — `server/Systems/DataService.luau`

Lo que normalmente se hace mal y acá ya está resuelto:

- Toda llamada al DataStore con `pcall` + retry y backoff exponencial.
- `UpdateAsync` siempre, nunca `GetAsync` + `SetAsync`.
- **Session locking**: una sola *sesión* posee el perfil a la vez. El lock
  guarda un `sessionId` único por carga, no sólo el `JobId`, así que dos
  sesiones del mismo jugador en el mismo servidor (salir y volver a entrar)
  son dueños distintos. Es lo que evita la duplicación de items. Si el lock lo
  tiene otra sesión, el claim se reintenta con espera antes de expulsar: al
  apagarse un servidor Roblox migra a los jugadores, y kickear al primer
  intento los echaría a todos. Los locks viejos se consideran huérfanos y se
  liberan solos.
- **Escrituras serializadas por jugador**: sin esto, un autosave en vuelo
  puede aterrizar después del save de salida, pisar datos nuevos con datos
  viejos y reinstalar un lock que ya nadie va a liberar.
- El perfil se **valida como serializable antes de escribirlo**. Un `Instance`,
  un `NaN` o una tabla con huecos que se cuele rompe todos los saves de ese
  jugador para siempre, y sin el chequeo sólo se nota por un `warn`.
- `DataService.save()` devuelve `false` si la escritura no llegó al DataStore.
  Un `UpdateAsync` cuyo transform aborta **no** tira error, así que reportar
  éxito por el `pcall` sería mentira.
- Guarda en los tres momentos: autosave (escalonado por `UserId`, para que 50
  jugadores no escriban en el mismo tick), salida del jugador y `BindToClose`.
- Migraciones de schema versionadas desde el día uno.
- Si la carga falla, el jugador se expulsa con un mensaje claro en vez de
  entrar con un perfil vacío que después le pisaría los datos reales.

El gameplay nunca toca el DataStore: lee y escribe la tabla en memoria que
devuelve `DataService.get(player)`.

### Remotes — `shared/RemoteSchema.luau` + `server/Systems/RemoteService.luau`

Todos los remotes se declaran en un solo archivo con su dirección, sus
validadores y su presupuesto de rate limit. El servidor los crea; el cliente
nunca. Cada handler pasa en orden por:

1. **Rate limit** (token bucket por jugador y por remote).
2. **Validación** de tipos y rangos.
3. El handler del sistema, que ya puede asumir sus tipos.

Registrar un handler para un nombre que no esté en el schema tira error al
arrancar, no silenciosamente.

Los validadores de `shared/Util/Guard.luau` cubren los agujeros que más se
explotan: `NaN` pasa `typeof(x) == "number"`, `math.huge` pasa cualquier
comparación de tipo, los strings sin tope de largo permiten mandar megabytes, y
una instancia que llega por un remote puede estar ya destruida.

### Economía — `server/Systems/EconomyService.luau`

Moneda e inventario autoritativos en el servidor. El catálogo y los precios
viven del lado servidor; el cliente manda un id y una cantidad, nada más. Las
transacciones son todo o nada.

`addCurrency` y `grantItem` validan su entrada aunque las llame otro sistema
del servidor, no sólo el borde del remote: un `NaN` o un infinito que entre al
perfil lo vuelve no serializable y rompe los saves de ese jugador para
siempre, y una cantidad negativa en `grantItem` dejaría inventario negativo.

### Rondas — `server/Systems/RoundService.luau`

Loop genérico intermedio → ronda → intermedio, **apagado por defecto**
(`Config.ROUNDS_ENABLED`). Sirve para arena, battle royale u obby con tiempo;
un tycoon o un sandbox lo deja en `false` y no paga nada. No sabe de mapas ni
de puntaje: expone `onStart` / `onEnd` y cada juego se engancha ahí.

### Cliente — `client/Controllers/`

- `NetController` — único punto de acceso a los remotes, validado contra el
  schema.
- `StateController` — espejo local del estado público. La UI lee de acá y se
  entera de los cambios por `subscribe()`, que llama una vez de entrada con el
  estado actual para que no haya caso especial de "todavía no llegó nada".

## Estructura

```text
src/shared  → ReplicatedStorage/Shared       tipos, config, schema, utilidades puras
src/server  → ServerScriptService/Server     sistemas autoritativos
src/client  → StarterPlayerScripts/Client    input, UI, render
```

Bootstrap en dos fases y en **orden explícito** (`BOOT_ORDER` en los dos
`init`): primero `init()` de todo, después `start()`. El orden es explícito y
no un recorrido de carpeta porque `RemoteService` tiene que crear los remotes
antes de que cualquier otro sistema registre un handler.

## Agregar un sistema

1. Si necesita remotes, declararlos en `shared/RemoteSchema.luau`.
2. Crear `src/server/Systems/MiSistema.luau` con `init()` y/o `start()`.
3. Sumar el nombre a `BOOT_ORDER` en `src/server/init.server.luau`, después de
   los sistemas de los que dependa.

Convenciones: `--!strict` en todo archivo, servidor autoritativo siempre,
lógica de juego en ModuleScripts puros para poder testearla, sin `_G`.

## Límites conocidos

- **Tamaño del perfil**: `inventory` y `stats` no tienen tope de cantidad de
  claves. El límite real de una key de DataStore es ~4 MB; si tu juego va a
  guardar listas que crecen sin fin (historial de partidas, logs), poneles
  tope o rotalas antes de llegar ahí.
- **`RoundService`** expone el remote `GetRoundState`, pero no hay un
  controlador de cliente que lo consuma: eso lo arma cada juego según cómo
  quiera mostrar la fase.
- Nada de esto se probó todavía en una sesión real de Studio con varios
  jugadores. La lógica está verificada estáticamente (sintaxis, lint, formato,
  build de Rojo) y revisada, no playtesteada.

## Chequeos

```bash
stylua src           # formato
stylua --check src   # lo que corre CI
selene src           # lint
rojo build --output build.rbxl   # valida el mapeo del proyecto
```

CI (`.github/workflows/ci.yml`) corre formato y lint en cada push y PR.
