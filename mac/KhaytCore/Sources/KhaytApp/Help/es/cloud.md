# Sincronización en la nube

Khayt Cloud lleva tu libro entre máquinas y da a tus clientes una página para
seguir su pedido. Es opcional: la app funciona perfectamente sin ella.

## Qué hace esta app

- **Comprobar**: compara tu libro con la nube y dice qué difiere, sin enviar nada.
  Es de solo lectura, así que es seguro usarla cuando no estás seguro.
- **Enviar lo que solo está aquí**: sube tu libro.
- **Bajar lo que solo está allí**: trae la copia de la nube y la fusiona.

## Tus secretos no salen

El libro contiene el token de la nube, las claves de API de las impresoras y los
secretos de almacenamiento. Antes de enviar nada, se quitan y se sustituyen por
máscaras. La copia que sale nunca los contiene.

## Bloqueo

**Libro → Bloquear Khayt Cloud** pone fin a la sincronización automática y olvida
la clave guardada en memoria. Es la forma de salir, y la única: conviene saberlo si
dejas un Mac en un lugar que no controlas.

## Dos máquinas

Si dos máquinas llevan este libro, actualiza ambas antes de fiarte de una
sincronización. Una versión más antigua puede llevar campos que una más nueva ha
cambiado, y gana quien escribió último, así que una máquina que se quedó en una
versión vieja puede devolver valores antiguos sin que nadie lo note.
