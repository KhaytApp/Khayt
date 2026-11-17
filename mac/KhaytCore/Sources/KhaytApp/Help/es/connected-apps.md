# Apps conectadas

Los laminadores que envían sus archivos laminados directamente a este Mac, y qué hacer cuando el emparejamiento no funciona.

## Antes de empezar

- Khayt para Mac. Emparejar un laminador no existe en la app de Windows o Linux.
- El servidor LAN encendido, con **Escuchar en todas las interfaces de red (LAN)** activado, en Ajustes → En línea. Apagado, el Mac solo se responde a sí mismo y ningún laminador puede alcanzarlo.
- OrcaSlicer 2.5.1 o posterior con el plugin de Khayt instalado, en un ordenador de la misma red que el Mac.
- Eres el dueño del taller o un encargado. Los demás no pueden emparejar ni quitar un laminador.

## Emparejar un laminador

- Abre **Apps conectadas** en la barra lateral y haz clic en **Emparejar un laminador**. Durante los dos minutos siguientes, un laminador de tu red puede pedir emparejarse, y el Mac muestra la dirección que hay que escribir.
- En OrcaSlicer, abre Khayt → Pair → On this network y escribe esa dirección tal cual.
- El Mac pregunta **¿Aprobar «nombre»?** y dice qué app lo pidió y desde qué dirección. Comprueba que es tu laminador.
- Ambas pantallas muestran ahora un número de seis cifras. Si son iguales, haz clic en **Los números coinciden — aprobar**. El laminador aparece en Laminadores emparejados.

## Si los números son distintos, deniega

Haz clic en **Denegar**. Números distintos significan que la petición no vino directamente de tu laminador: algo más en la red puede estar en medio. No apruebes para ver qué pasa. Comprueba que el laminador está en tu propia red y vuelve a emparejar. Un clic en Emparejar un laminador permite tres intentos.

## Qué ve un laminador emparejado y qué no

Puede enviar archivos a la bandeja Desde tu laminador y ver la cola de trabajos: solo números, etapas y máquinas, nunca títulos ni clientes. También ve tus máquinas, el nombre del taller y cuántos archivos esperan en la bandeja. Nunca puede leer tu libro, tus clientes, tus precios ni tus ajustes, y nunca ve tu PIN de la LAN. Su clave se guarda en el llavero de este Mac, no en tu libro.

## La bandeja Desde tu laminador

Lo que envía un laminador espera en Desde tu laminador, en la pantalla Apps conectadas, con el peso y el tiempo de impresión del laminador, qué laminador lo envió y qué pidió (un presupuesto, un trabajo, una impresión). Para cada archivo elige **Añadir a la biblioteca**, **Nuevo trabajo** o **Nuevo presupuesto**, o **Descartar**. Nada se convierte en trabajo ni empieza a imprimirse hasta que tú eliges: lo que pide el laminador es solo una sugerencia. El mismo archivo enviado dos veces se guarda una vez, y Khayt te lo dice. Pueden esperar hasta 100 archivos. La bandeja es una carpeta junto a tu libro en este Mac; no se sincroniza ni se envía a ningún sitio.

## Quitar un laminador

En la pantalla Apps conectadas, haz clic en **Quitar…** junto al laminador y confirma. Deja de enviar a este Mac al momento; para volver a usarlo, emparéjalo de nuevo. Los archivos que ya envió se quedan en tu bandeja. Cambiar el PIN de la LAN también desconecta todos los laminadores emparejados, junto con los teléfonos emparejados.

## Cuando el emparejamiento no funciona

- **Emparejar un laminador está atenuado:** enciende el servidor LAN y Escuchar en todas las interfaces de red (LAN) en Ajustes → En línea. Si están encendidos, pregunta al dueño o a un encargado: puede que tu rol no permita cambiar ajustes.
- **El laminador no alcanza el Mac:** pon los dos ordenadores en la misma red (una wifi de invitados suele separar los dispositivos), escribe la dirección exacta con el puerto y, si el cortafuegos de macOS está activo, permite que Khayt acepte conexiones entrantes.
- **El laminador dice que el emparejamiento está cerrado:** está abierto dos minutos y se cierra al aprobar un laminador. Vuelve a hacer clic en Emparejar un laminador.
- **No se pudo leer el PIN de la LAN del llavero:** no se emparejó nada. Vuelve a definir el PIN en Ajustes → En línea y empareja de nuevo. Eso desconecta teléfonos y laminadores: empareja esos también.
- **El laminador dice que la bandeja está llena:** esperan 100 archivos. Toma o descarta algunos y vuelve a enviar.
