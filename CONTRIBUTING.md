# Contribuir a wu-cli

Guia para colaborar en el desarrollo de wu-cli, el CLI nativo en Zig para wu-framework.

---

## Requisitos previos

- **Zig 0.15.2+** -- compilador y build system
- **Node.js 18+** -- necesario para los compiladores de frameworks (Svelte, Vue, Solid)
- **Git** -- control de versiones

## Estructura del proyecto

```
wu-cli/
  src/
    commands/        Handlers de comandos CLI (dev, build, create, add, info, serve)
    runtime/         Core del dev server nativo
      dev_server.zig   Servidor HTTP thread-per-connection
      http_parser.zig  Parser HTTP/1.1 con SIMD
      resolve.zig      Resolucion de modulos NPM (puro Zig)
      transform.zig    Borrado de TS + reescritura de imports
      jsx_transform.zig  Transformacion nativa JSX (React/Preact)
      compile.zig      Compilacion de frameworks (3 niveles)
      cache.zig        Cache de dos niveles (memoria + disco)
      ws_protocol.zig  WebSocket RFC 6455
      mime.zig         Deteccion de tipos MIME
    config/          Carga y validacion de wu.config.json
  build.zig          Build script de Zig
```

## Flujo de trabajo con Git

### Ramas

| Rama | Proposito |
|------|-----------|
| `master` | Rama protegida. Solo se actualiza via Merge Request. |
| `develop` | Rama de integracion (opcional, para cuando el equipo crezca). |
| `feature/<nombre>` | Nuevas funcionalidades. |
| `fix/<nombre>` | Correccion de bugs. |
| `refactor/<nombre>` | Refactoring sin cambios funcionales. |

### Proceso para contribuir

1. **Crear rama desde master:**
   ```bash
   git checkout master
   git pull origin master
   git checkout -b feature/mi-feature master
   ```

2. **Desarrollar y commitear** con mensajes descriptivos (ver convencion abajo).

3. **Push a GitLab:**
   ```bash
   git push -u origin feature/mi-feature
   ```

4. **Crear Merge Request** en GitLab apuntando a `master`.

5. **Review y merge.** Se recomienda squash merge para mantener el historial limpio.

### Convencion de commits

```
<tipo>: <descripcion corta>

[cuerpo opcional con mas detalle]

Co-Authored-By: Nombre <email>
```

**Tipos validos:**

| Tipo | Uso |
|------|-----|
| `feat` | Nueva funcionalidad |
| `fix` | Correccion de bug |
| `refactor` | Refactoring sin cambio funcional |
| `test` | Agregar o modificar tests |
| `docs` | Documentacion |
| `chore` | Tareas de mantenimiento, CI, dependencias |

### Ejemplo de commit

```
feat: add gzip compression for module responses

Compress /@modules/ responses using deflate when the browser
supports Accept-Encoding: gzip. Reduces transfer size ~70%.

Co-Authored-By: Jose Padre <jose@example.com>
```

## Compilar y probar

```bash
# Compilar el binario
zig build

# Ejecutar tests
zig build test

# Ejecutar con argumentos (ejemplo: comando dev)
zig build run -- dev

# O ejecutar el binario directamente
./zig-out/bin/wu dev
```

## Reglas del proyecto

1. **No se hace push directo a `master`.** Todo cambio pasa por Merge Request.

2. **Los tests deben pasar** antes de mergear cualquier MR.

3. **El binario no tiene dependencias externas de Zig.** No se agregan paquetes de terceros al build.zig. Todo el runtime se escribe en Zig puro.

4. **Node.js solo se usa para compiladores de frameworks** (Svelte, Vue, Solid). Cualquier funcionalidad nueva debe implementarse en Zig nativo siempre que sea posible.

5. **Preferir transformaciones nativas en Zig** sobre subprocesos Node.js. Si un framework permite compilacion nativa, implementarla en Zig (como se hizo con JSX para React/Preact).

6. **Mantener la arquitectura de cache de dos niveles.** Toda compilacion debe pasar por el sistema de cache (memoria + disco) para garantizar tiempos de respuesta rapidos en desarrollo.

## Patrones de Zig 0.15.2 a tener en cuenta

Zig 0.15.2 tiene diferencias importantes con versiones anteriores. Estos son los patrones que usamos en el proyecto:

### ArrayList

`std.ArrayList` usa `.empty` para inicializacion. El allocator se pasa a cada operacion, no al constructor:

```zig
var list: std.ArrayList(u8) = .empty;
defer list.deinit(allocator);
try list.append(allocator, value);
const slice = try list.toOwnedSlice(allocator);
```

### Parametros de funcion son const

Los parametros de funcion son inmutables. Para modificarlos, crear una copia local:

```zig
fn process(path: []const u8) void {
    var local_path = path;
    // ahora se puede modificar local_path
}
```

### Iterador de directorios

`entry.name` del iterador de directorios apunta a un buffer temporal que se sobreescribe en la siguiente iteracion. Duplicar el string si se necesita persistir:

```zig
const name = try allocator.dupe(u8, entry.name);
```

### Output de debug

Usar `std.debug.print()` para output de diagnostico. `std.io.getStdIn()` fue removido en 0.15.2. Para stdin en Windows:

```zig
const handle = std.os.windows.GetStdHandle(std.os.windows.STD_INPUT_HANDLE);
const file = std.fs.File{ .handle = handle };
```

### child process cwd

El campo `child.cwd` es `?[]const u8` (nullable), no un slice directo.

## Estructura de un nuevo comando

Para agregar un nuevo comando CLI:

1. Crear el archivo en `src/commands/mi_comando.zig`.
2. Exportar una funcion publica `pub fn execute(allocator: std.mem.Allocator, args: [][]const u8) !void`.
3. Registrar el comando en el dispatcher principal (`src/main.zig`).
4. Agregar la entrada en la tabla de ayuda.

## Estructura de un nuevo modulo de runtime

Para agregar funcionalidad al dev server:

1. Crear el archivo en `src/runtime/mi_modulo.zig`.
2. Integrarlo en `dev_server.zig` donde corresponda (request handling, middleware, etc.).
3. Si involucra compilacion, respetar la jerarquia de tres niveles: Zig nativo -> Daemon -> Node fallback.
4. Si cachea resultados, usar el sistema de cache existente en `cache.zig`.
