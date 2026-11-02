# Máquinas e impresoras

En qué imprimes y, cuando conectas una, qué está haciendo ahora mismo.

## Añadir una máquina

Una máquina es un registro: su nombre, de qué tipo es, el tamaño de su cama, lo que
costó y lo que cuesta hacerla funcionar. Esos dos últimos datos son los que dejan
que Khayt te diga cuánto vale una hora en esa máquina.

## Conectar con una impresora

Una máquina puede vincularse a la propia impresora. Khayt habla siete protocolos:

- **Moonraker / Klipper**, incluida la Snapmaker U1.
- **OctoPrint**
- **PrusaLink**
- **Duet**
- **Repetier**
- **Bambu**: solo estado. Bambu ahora exige su propio conector para el control
  remoto.
- **Resina Elegoo (SDCP)**

Introduce la dirección y la clave, pulsa **Probar**, y Khayt dice qué respondió. La
clave queda sellada en el Llavero del Mac, no escrita en el libro.

## Estado en vivo

Una impresora conectada muestra qué imprime, cuánto lleva, las temperaturas y
cuánto falta.

Dos cosas que conviene saber sobre esa lectura:

- **El avance se mide por capas, no por bytes**, cuando la impresora lo indica. La
  posición en bytes dentro de un archivo no mide el trabajo: un modelo de 31 MB
  marcaba un 0,7 % cuando iba casi por el 20 %.
- **El tiempo restante es la estimación del slicer** cuando el archivo trae una, y
  solo se extrapola cuando no.

## Una impresora que se mudó

Las impresoras cambian de dirección cuando se reinicia un router. Khayt reconoce
una máquina que ya ha visto por el número de serie de su propia placa y la sigue a
la nueva dirección, en lugar de mostrarla como desconectada.

## Quitar un objeto de una placa

En una impresora Klipper o Moonraker, un solo objeto de una placa puede saltarse
mientras el resto de la placa sigue: para la pieza que se ha soltado.

**No se puede deshacer.** Klipper no vuelve a imprimir las capas omitidas mientras
un objeto estaba descartado, así que un objeto descartado por error es desecho.
