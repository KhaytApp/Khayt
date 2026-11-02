# Sincronização com a nuvem

O Khayt Cloud leva o seu livro entre máquinas e dá aos seus clientes uma página
para acompanhar o pedido. É opcional: o app funciona por completo sem ele.

## O que este app faz

- **Verificar** — compara o seu livro com a nuvem e diz o que é diferente, sem
  enviar nada. Somente leitura, então é seguro usar quando você não tem certeza.
- **Enviar** — sobe o seu livro.
- **Trazer** — baixa a cópia da nuvem e a mescla.

## Seus segredos não saem

O livro guarda o token da nuvem, as chaves de API das impressoras e quaisquer
segredos de armazenamento. Antes de qualquer envio, eles são retirados e
substituídos por máscaras. A cópia que sai nunca os contém.

## Bloqueio

**Livro → Bloquear o Khayt Cloud** encerra a sincronização automática e esquece
a chave mantida na memória. É o caminho de volta, e o único — vale saber se você
vai deixar um Mac em um lugar que não controla.

## Duas máquinas

Se duas máquinas mantêm este livro, atualize as duas antes de confiar em uma
sincronização. Uma versão mais antiga pode carregar campos que uma mais nova
alterou, e vale quem escreveu por último — então uma máquina deixada para trás
numa versão antiga pode, sem alarde, recolocar valores antigos.
