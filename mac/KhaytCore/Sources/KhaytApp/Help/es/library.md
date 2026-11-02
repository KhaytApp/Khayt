# La biblioteca de modelos

Cada modelo que imprimes, con su imagen, de qué está hecho y cuánto cuesta
producirlo.

## Traer modelos

Tres vías de entrada, todas iguales por debajo:

- El botón **Importar modelos** de la biblioteca.
- Arrastrar archivos o carpetas enteras a la biblioteca.
- **Libro → Añadir modelo**, o ⇧⌘I.

Las carpetas se recorren, así que puedes apuntar Khayt a una descarga y dejar que
encuentre los modelos dentro. Todo lo que no sea un modelo se pasa por alto en
silencio.

## Las carpetas se convierten en grupos

**La carpeta de la que vino un modelo se convierte en el grupo en el que se
archiva.** Una descarga de siete modelos en siete carpetas llega como siete
grupos, no como un montón plano.

Las carpetas de empaquetado se atraviesan. Un modelo en

`Saudi Kings/King Abdulaziz/STL/presupported/crown.stl`

se archiva en **King Abdulaziz**, no en *presupported*, *STL* ni *files*, porque
esos describen el archivo en lugar de nombrar la cosa.

Un archivo que eliges solo no se agrupa. Un archivo no es un conjunto.

## Duplicados

Un modelo que ya tienes se reconoce por el contenido del archivo, no por su nombre,
y se rechaza en lugar de añadirse dos veces. Renombrar un archivo no lo engaña;
reexportar el mismo modelo desde un slicer suele cambiar los bytes, y entonces sí
es realmente un archivo nuevo.

## Mirar los modelos

La biblioteca es una cuadrícula porque un taller de impresión reconoce un modelo
al verlo. La barra espaciadora abre Vista Previa rápida, como en el Finder. Las
flechas recorren la cuadrícula, y en una ventana en árabe la recorren en el
sentido correcto.
