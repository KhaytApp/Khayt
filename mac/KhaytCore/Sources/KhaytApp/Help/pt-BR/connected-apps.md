# Apps conectados

Os fatiadores que enviam arquivos fatiados direto para este Mac, e o que fazer quando o pareamento não funciona.

## Antes de começar

- Khayt para Mac. Parear um fatiador não existe no app de Windows ou Linux.
- O servidor LAN ligado, com **Escutar em todas as interfaces de rede (LAN)** ativado, em Ajustes → Online. Desligado, o Mac responde só a si mesmo e nenhum fatiador consegue alcançá-lo.
- OrcaSlicer 2.5.1 ou mais novo com o plugin do Khayt instalado, em um computador na mesma rede do Mac.
- Você é o dono da oficina ou um gerente. Os outros não podem parear nem remover um fatiador.

## Parear um fatiador

- Abra **Apps conectados** na barra lateral e clique em **Parear um fatiador**. Nos dois minutos seguintes, um fatiador da sua rede pode pedir para parear, e o Mac mostra o endereço a digitar.
- No OrcaSlicer, abra Khayt → Pair → On this network e digite esse endereço exatamente.
- O Mac pergunta **Aprovar “nome”?** e diz qual app pediu e de qual endereço. Confira se é o seu fatiador.
- As duas telas agora mostram um número de seis dígitos. Se forem iguais, clique em **Os números conferem — aprovar**. O fatiador aparece em Fatiadores pareados.

## Se os números forem diferentes, recuse

Clique em **Recusar**. Números diferentes significam que o pedido não veio direto do seu fatiador: outra coisa na rede pode estar no meio. Não aprove para ver o que acontece. Confira se o fatiador está na sua própria rede e pareie de novo. Um clique em Parear um fatiador permite três tentativas.

## O que um fatiador pareado vê e o que não vê

Ele pode enviar arquivos para a caixa Do seu fatiador e ver a fila de trabalhos: só números, etapas e máquinas, nunca títulos ou clientes. Também vê suas máquinas, o nome da oficina e quantos arquivos esperam na caixa. Nunca pode ler seu livro, seus clientes, seus preços ou ajustes, e nunca vê seu PIN da LAN. A chave dele fica nas Chaves deste Mac, não no seu livro.

## A caixa Do seu fatiador

O que um fatiador envia espera em Do seu fatiador, na tela Apps conectados, com o peso e o tempo de impressão do fatiador, qual fatiador enviou e o que ele pediu (um orçamento, um trabalho, uma impressão). Para cada arquivo escolha **Adicionar à biblioteca**, **Novo trabalho** ou **Novo orçamento**, ou **Descartar**. Nada vira trabalho e nenhuma impressão começa até você escolher: o pedido do fatiador é só uma sugestão. O mesmo arquivo enviado duas vezes é guardado uma vez, e o Khayt avisa. Até 100 arquivos podem esperar. A caixa é uma pasta ao lado do seu livro neste Mac; não é sincronizada nem enviada a lugar nenhum.

## Remover um fatiador

Na tela Apps conectados, clique em **Remover…** ao lado do fatiador e confirme. Ele para de enviar a este Mac na hora; para usá-lo de novo, pareie de novo. Os arquivos que ele já enviou continuam na sua caixa. Mudar o PIN da LAN também desconecta todos os fatiadores pareados, junto com os celulares pareados.

## Quando o pareamento não funciona

- **Parear um fatiador está acinzentado:** ligue o servidor LAN e Escutar em todas as interfaces de rede (LAN) em Ajustes → Online. Se estiverem ligados, peça ao dono ou a um gerente: talvez seu papel não possa mudar ajustes.
- **O fatiador não alcança o Mac:** coloque os dois computadores na mesma rede (um Wi‑Fi de visitantes costuma separar os aparelhos), digite o endereço exato com a porta e, se o firewall do macOS estiver ativo, permita que o Khayt aceite conexões de entrada.
- **O fatiador diz que o pareamento está fechado:** ele fica aberto dois minutos e fecha quando um fatiador é aprovado. Clique de novo em Parear um fatiador.
- **Não foi possível ler o PIN da LAN nas Chaves:** nada foi pareado. Defina o PIN de novo em Ajustes → Online e pareie de novo. Isso desconecta celulares e fatiadores: pareie esses também.
- **O fatiador diz que a caixa está cheia:** 100 arquivos esperam. Pegue ou descarte alguns e envie de novo.
