# Cuando algo va mal

## «Abierto en solo lectura»

Khayt para Windows y Linux tiene el libro abierto, o lo tiene otro Mac. Una app
escribe un libro a la vez, a propósito: dos a la vez es como desaparece el trabajo
de una tarde. Ciérralo allí y usa **Libro → Recargar desde disco**.

## Una cifra de aquí no coincide con la otra app

No debería: las dos calculan con las mismas reglas compartidas. Hay dos cosas que
hacen parecer que no coinciden:

- **Los libros son distintos.** Mira el nombre de arriba a la izquierda; un libro de
  desarrollo y uno distribuido son dos archivos diferentes.
- **Uno está desactualizado.** **Libro → Recargar desde disco** después de que la
  otra app haya escrito.

Si sigue sin coincidir, vale la pena avisarlo, con las dos cifras.

## La impresora no dice nada

- Comprueba la dirección y la clave con **Probar** en la máquina.
- Una impresora que cambió de dirección suele seguirse automáticamente, pero solo
  una vez que Khayt ha visto su número de serie: una impresora a la que nunca ha
  llegado no puede reconocerse después.
- Las impresoras Bambu solo informan del estado. El control remoto necesita el
  conector propio de Bambu.

## Un modelo no se importa

- Puede que ya esté. Khayt reconoce un archivo por su contenido, no por su nombre,
  y rechaza un duplicado.
- Solo se aceptan archivos de modelo y G-code; todo lo demás de una carpeta se pasa
  por alto.
- Importar la carpeta de tu propia biblioteca en sí misma no hace nada, a propósito.

## Conseguir una compilación que funcione

**Khayt → Buscar actualizaciones…**. Si la app no arranca en absoluto, ninguna
actualización puede llegarte (Sparkle se ejecuta dentro de la app) y la compilación
hay que descargarla a mano desde la página de versiones.
