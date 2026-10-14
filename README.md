# Quiz ao Vivo

Quiz para audiência ao vivo: o apresentador projeta a tela, o público entra pelo celular com PIN + nome.

- **Participantes:** `index.html` (página inicial do site). O QR code do telão já preenche o PIN.
- **Apresentador:** `host.html` (editor de perguntas + condução ao vivo).

## Como funciona

- Perguntas de múltipla escolha (2 a 4 alternativas) ou verdadeiro/falso, com tempo de 5 a 120 s.
- Pontuação: até 1.000 pontos por pergunta, multiplicados por 2 ou 3 nas perguntas com bônus.
  Fórmula: `pontos × (1 − (tempo de resposta ÷ tempo da pergunta) ÷ 2)`; acerto em menos de 0,5 s leva o máximo. Erro vale 0.
- Antes de cada pergunta há uma contagem regressiva (5 s na primeira, 4 s nas outras). O horário de início é definido pelo servidor e cada celular sincroniza o relógio com ele, então o tempo abre igual pra todos e a velocidade é medida no servidor.
- A pergunta fecha sozinha quando o tempo acaba ou quando todo mundo respondeu.
- Fluxo: sala de espera → pergunta → resultado da pergunta → ranking (top 5) → … → pódio final.

## Backend

Supabase (projeto "Quiz ao Vivo", região São Paulo). As tabelas ficam fechadas por RLS; tudo passa por funções em `supabase/schema.sql`
que exigem a chave de edição do quiz, a chave do apresentador ou o segredo de cada jogador.
Os celulares consultam o estado a cada 1,5–2 s (sem WebSocket), o que mantém o projeto dentro dos limites do plano gratuito.

Plano gratuito do Supabase: o projeto é pausado após uma semana sem uso. Se isso acontecer, reative no painel do Supabase antes do evento.
