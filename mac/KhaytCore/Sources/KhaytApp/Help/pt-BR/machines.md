# Máquinas e impressoras

Aquilo em que você imprime e — quando você conecta uma — o que ela está fazendo
agora.

## Adicionar uma máquina

Uma máquina é um registro: o nome, o tipo, o tamanho da mesa, quanto custou e
quanto custa operá-la. Os dois últimos é que permitem ao Khayt dizer quanto vale
uma hora naquela máquina.

## Conectar a uma impressora

Uma máquina pode ser ligada à impressora em si. O Khayt fala sete protocolos:

- **Moonraker / Klipper** — incluindo a Snapmaker U1.
- **OctoPrint**
- **PrusaLink**
- **Duet**
- **Repetier**
- **Bambu** — somente status. A Bambu agora exige o conector próprio dela para o
  controle remoto.
- **Resina Elegoo (SDCP)**

Informe o endereço e a chave, pressione **Testar** e o Khayt diz o que
respondeu. A chave fica guardada no Chaveiro do Mac, e não escrita no livro.

## Status ao vivo

Uma impressora conectada mostra o que está imprimindo, quanto já andou, as
temperaturas e quanto tempo falta.

Duas coisas que vale saber sobre essa leitura:

- **O progresso é por camada, não por bytes**, quando a impressora informa. A
  posição em bytes dentro de um arquivo não mede trabalho — um modelo de 31 MB
  apareceu como 0,7% pronto quando estava perto de 20%.
- **O tempo restante é a estimativa do fatiador** quando o arquivo traz uma, e
  só é extrapolado quando não traz.

## Uma impressora que mudou de lugar

As impressoras ganham endereços novos quando um roteador reinicia. O Khayt
reconhece uma máquina que já viu pelo número de série da própria placa e a segue
até o novo endereço, em vez de mostrá-la como offline.

## Descartar um objeto de uma mesa

Em uma impressora Klipper ou Moonraker, um único objeto da mesa pode ser pulado
enquanto o resto da mesa continua — para a peça que se soltou.

**Não dá para desfazer.** O Klipper não reimprime as camadas puladas enquanto um
objeto estava descartado, então um objeto descartado por engano é sucata.
