# Accio Optimizer v1.0.1

Ferramenta de manutenção, diagnóstico e otimização segura para Windows 10 e Windows 11.

## Como executar

1. Extraia a pasta/ZIP em um local permanente.
2. Clique com o botão direito em `Executar_Accio_Optimizer.cmd`.
3. Execute normalmente; o PowerShell solicitará elevação de Administrador via UAC.
4. No primeiro uso, recomendo:
   - `[7] Diagnóstico`
   - `[12] Criar snapshot + Ponto de Restauração`
   - `[1] Otimização segura recomendada`
5. Use `[6] Perfil Accio Performance` somente se quiser priorizar desempenho sobre efeitos visuais/consumo.

## Onde ficam os backups e logs

O programa cria:

- `%ProgramData%\AccioOptimizer\Logs`
- `%ProgramData%\AccioOptimizer\Backups`

Essas pastas são graváveis somente por `SYSTEM` e Administradores; o usuário que executou o programa mantém acesso de leitura. Snapshots com proprietário, computador, usuário ou destinos de Registro inesperados são recusados pelo rollback.

Cada snapshot contém:
- `state.json` com valores de Registro relevantes, plano de energia e estado do TRIM;
- exportações `.reg` complementares;
- lista de itens de inicialização;
- estado dos serviços;
- lista de planos de energia;
- informações de rede;
- estado do TRIM.

A opção `[13] Restaurar snapshot / rollback` restaura os ajustes persistentes feitos pelo Accio.
Planos de energia criados pelo perfil Accio Performance também são removidos durante o rollback correspondente.

## Proteção adicional

Antes de alterações persistentes, o Accio tenta criar um Ponto de Restauração do Windows.
O Windows pode impedir um novo ponto quando já existe um criado recentemente ou quando a Proteção do Sistema está bloqueada por política. Mesmo nesses casos, o snapshot interno do Accio continua disponível.

IMPORTANTE:
- rollback não recupera arquivos temporários apagados;
- rollback não recupera arquivos removidos da Lixeira;
- um Ponto de Restauração do Windows é uma camada adicional, não substitui backup dos seus arquivos pessoais.

## O que a otimização recomendada faz

- limpa temporários do usuário e Windows;
- limpa o cache do Delivery Optimization quando o cmdlet está disponível;
- executa `DISM /Online /Cleanup-Image /StartComponentCleanup` sem `/ResetBase`;
- usa `Optimize-Volume` para o Windows escolher a operação correta:
  - SSD compatível: ReTrim;
  - HDD: análise/desfragmentação apropriada;
  - outros tipos: comportamento apropriado ao dispositivo.

## Perfil Accio Performance

Opcional e reversível.

- tenta ativar o plano Alto Desempenho;
- se necessário e suportado, cria um plano derivado;
- desativa transparência;
- reduz animações de janela;
- reduz atraso de menus;
- seleciona preferência de efeitos visuais por desempenho.

Em notebooks, Alto Desempenho pode aumentar consumo e temperatura.

## O que o Accio NÃO faz

Por segurança e por falta de benefício universal, ele não:
- desativa Microsoft Defender;
- desativa Windows Update;
- desativa SysMain ou Windows Search;
- desativa serviços de impressão/Bluetooth/Store;
- apaga Prefetch;
- limpa RAM/standby list;
- desativa pagefile;
- mexe em HPET/BCD/timer resolution;
- aplica tweaks globais de TCP/Nagle;
- remove aplicativos do sistema automaticamente;
- usa `/ResetBase` na rotina recomendada.

## Reparação

A opção `[5]` executa:

1. `DISM /Online /Cleanup-Image /RestoreHealth /NoRestart`
2. `SFC /scannow`

Os logs nativos ficam em:
- `%WINDIR%\Logs\DISM\dism.log`
- `%WINDIR%\Logs\CBS\CBS.log`

## WinGet

A opção `[10]` primeiro mostra as atualizações disponíveis.
Nada é instalado até você confirmar.

## Compatibilidade

- Windows 10
- Windows 11
- Windows PowerShell 5.1 (Desktop), iniciado automaticamente pelo lançador
- requer privilégios de Administrador para operações de manutenção

## Testes seguros

Os testes de sintaxe, propagação de erros, proteção de caminhos e validação de snapshots não alteram configurações do Windows:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\AccioOptimizer.Tests.ps1
```

## Observação

O Accio Optimizer prioriza estabilidade e reversibilidade. Ele não promete aumento artificial de FPS nem executa ajustes de Registro/serviços sem ganho técnico consistente.

Se uma etapa obrigatória falhar, a operação passa a ser registrada como parcialmente concluída e o lançador recebe um código de erro. Consulte o log antes de repetir a operação.

## Alterações da versão 1.0.1

- corrigida a falha ao processar linhas vazias retornadas por DISM, SFC e outros executáveis;
- operações compostas agora propagam falhas em vez de anunciar sucesso total;
- gravações críticas usam erros terminantes e o `state.json` é validado após a criação;
- snapshots são protegidos e validados antes do rollback;
- caminhos de limpeza perigosos e links/junctions são recusados;
- caminhos privilegiados são obtidos pelas APIs do Windows, sem confiar em variáveis de ambiente adulteráveis;
- a limpeza de DNS saiu da otimização recomendada e passou a ser uma ação explícita de diagnóstico;
- diretórios equivalentes por nome curto/longo deixam de ser limpos duas vezes;
- planos de energia criados pelo Accio passam a ser registrados para remoção no rollback;
- o lançador aguarda o processo elevado e recebe seu código de saída;
- a execução é recusada quando a elevação usa uma conta diferente, protegendo ajustes em `HKCU`.
