# Impianto LaTeX

Tutto quello che serve per far esistere e compilare il documento. Niente di esotico: la
relazione deve compilare sul portatile di chi la consegna, non su una distribuzione
particolare.

## Struttura dei file

```
doc/
  main.tex            preambolo, frontespizio, \input delle sezioni
  refs.bib            solo se si usa biblatex; con meno di dieci fonti si evita
  sections/
    01-introduction.tex
    02-requirements.tex
    ...
  figures/
    architecture.pdf
    ...
```

Una sezione per file. Serve a due cose: si compila un capitolo alla volta durante la
stesura, e i diff restano leggibili quando si lavora in due.

Per compilare una sola sezione mentre si scrive, `\includeonly{sections/04-architecture}`
nel preambolo. Si toglie prima della consegna.

## Preambolo

Testato con MiKTeX. Ogni pacchetto sta qui perché serve; non aggiungerne "per sicurezza".

```latex
\documentclass[11pt,a4paper]{article}

\usepackage[T1]{fontenc}
\usepackage[utf8]{inputenc}
\usepackage{lmodern}
\usepackage[english]{babel}
\usepackage{microtype}                    % giustificazione decente, meno overfull box

\usepackage[a4paper,margin=2.7cm]{geometry}
\usepackage{graphicx}
\usepackage{booktabs}                     % tabelle senza righe verticali
\usepackage{tabularx}
\usepackage{enumitem}
\usepackage{listings}
\usepackage{xcolor}
\usepackage{caption}
\usepackage[hidelinks]{hyperref}          % hidelinks: niente riquadri colorati in stampa
\usepackage{cleveref}                     % \cref{sec:...} scrive da solo "Section 4"

\setlist{itemsep=2pt, parsep=0pt, topsep=4pt}

\definecolor{codebg}{gray}{0.96}
\definecolor{codekw}{RGB}{0,80,140}
\definecolor{codecm}{RGB}{100,110,100}

\lstset{
  basicstyle=\ttfamily\footnotesize,
  keywordstyle=\color{codekw}\bfseries,
  commentstyle=\color{codecm}\itshape,
  stringstyle=\color{black!70},
  backgroundcolor=\color{codebg},
  breaklines=true,
  breakatwhitespace=true,
  showstringspaces=false,
  frame=single,
  framerule=0pt,
  xleftmargin=8pt,
  aboveskip=8pt, belowskip=8pt,
  captionpos=b,
}

% JSON non è tra i linguaggi predefiniti di listings
\lstdefinelanguage{json}{
  morestring=[b]",
  morecomment=[l]{//},
  literate=
    *{:}{{{\color{codekw}:}}}{1}
     {,}{{{\color{codekw},}}}{1}
     {\{}{{{\color{codekw}\{}}}{1}
     {\}}{{{\color{codekw}\}}}}{1}
     {[}{{{\color{codekw}[}}}{1}
     {]}{{{\color{codekw}]}}}{1},
}
```

Note su cosa **non** mettere:

- `\usepackage{times}` o simili: obsoleti, `lmodern` va bene.
- `minted`: rende meglio di `listings` ma richiede Python, Pygments e `-shell-escape`, cioè
  tre modi in più di non compilare sulla macchina di qualcun altro.
- `\usepackage{setspace}` con interlinea 1.5: gonfia il conteggio pagine e si vede.
- `\usepackage{fancyhdr}` per un report da trenta pagine: non serve.

## Frontespizio

BlackNet, il modello di riferimento, usa un frontespizio semplice: università, corso di
laurea, corso, titolo, membri del gruppo, anno accademico. Si fa a mano senza pacchetti:

```latex
\begin{titlepage}
\centering
{\large University of Pisa\par}
{\large Master's Degree in Computer Engineering\par}
{\large Distributed Systems and Middleware Technologies\par}
\vspace{3.5cm}
{\Huge\bfseries VoltShare\par}
\vspace{0.5cm}
{\Large Project Documentation\par}
\vfill
{\large Group members:\par Nome Cognome\par Nome Cognome\par}
\vspace{1cm}
{\large Academic Year 2025/2026\par}
\end{titlepage}
\tableofcontents
\newpage
```

## Compilazione

Su questa macchina la toolchain c'è: MiKTeX in
`C:\Users\andrea\AppData\Local\Programs\MiKTeX\miktex\bin\x64\`, con `pdflatex`, `latexmk`,
`biber` e `bibtex`.

```powershell
latexmk -pdf -interaction=nonstopmode -halt-on-error main.tex
latexmk -c        # pulisce gli ausiliari, tiene il PDF
```

`latexmk` decide da solo quante passate servono per indice, riferimenti incrociati e
bibliografia. Non lanciare `pdflatex` a mano tre volte.

**Se si blocca in attesa di un pacchetto**: MiKTeX installa al volo, ma di default apre una
finestra di conferma che in una sessione non interattiva non risponde nessuno. Per evitarlo:

```powershell
latexmk -pdf -pdflatex="pdflatex --enable-installer %O %S" -interaction=nonstopmode main.tex
```

**Cosa guardare nel log**, in ordine di gravità:

1. `! LaTeX Error` / `! Undefined control sequence`: rotto, si ferma tutto.
2. `LaTeX Warning: There were undefined references`: manca una passata o un `\label`.
3. `Overfull \hbox (Npt too wide)`: una riga sborda nel margine. Sotto i 10pt si ignora;
   sopra, quasi sempre è un URL o un identificatore lungo dentro `\texttt`. Si risolve con
   `\url{}` (hyperref sa spezzare) o con `\-` per suggerire la sillabazione.
4. `Underfull \hbox (badness 10000)`: righe con spazi larghi, cosmetico.

## Tabelle

`booktabs`, e nient'altro: `\toprule`, `\midrule`, `\bottomrule`. Niente righe verticali,
niente `\hline` doppi.

```latex
\begin{table}[t]
\centering
\caption{Nodes of the deployment.}
\label{tab:nodes}
\begin{tabularx}{\textwidth}{l l X}
\toprule
Node & Technology & Responsibility \\
\midrule
Back office & Java / Tomcat & Authentication, directory, billing \\
Coordinator & Erlang/OTP & Claims, cluster map, election \\
\bottomrule
\end{tabularx}
\end{table}
```

`tabularx` con una colonna `X` è quello che serve nel 90% dei casi: le colonne strette
restano strette e la descrizione va a capo da sola.

## Figure

Un documento di sistemi distribuiti vive di due o tre figure: il diagramma di deployment,
uno o due diagrammi di sequenza per i protocolli critici, eventualmente una macchina a
stati.

Ordine di preferenza:

1. **PDF vettoriale esportato** da draw.io, Excalidraw o simili. Veloce da fare, si rilegge
   bene, si modifica senza toccare LaTeX.
2. **TikZ** se il diagramma è semplice e regolare, o se deve stare in versione sorgente.
   Costa tempo: non iniziare a impararlo la settimana prima della consegna.
3. **PNG**: solo per screenshot dell'interfaccia o dei log. Mai per diagrammi, sfocano.

Regole: ogni figura ha una `\caption` che dice cosa mostra (non che ripete il titolo della
sezione), una `\label`, ed è citata nel testo con `\cref{fig:...}`. Una figura mai citata è
una figura da togliere.

## Listati di codice

Un frammento di codice sta nel documento solo se **si commenta**. Venti righe di `gen_server`
incollate senza spiegazione riempiono pagina e basta.

```latex
\begin{lstlisting}[language=Erlang, caption={Claim request handler.}, label={lst:claim}]
handle_call({claim, Vehicle, Station}, _From, State) ->
    ...
\end{lstlisting}
```

`listings` conosce già `Erlang`, `Java`, `SQL`, `XML`. Per JSON c'è la definizione nel
preambolo sopra.

Alternativa quasi sempre migliore: descrivere il protocollo con una **tabella di messaggi**
(nome, direzione, payload, effetto) invece che con il codice che li gestisce. Occupa meno e
si legge meglio.

## Bibliografia

Con meno di dieci riferimenti, `thebibliography` a mano evita `biber` e i suoi problemi di
versione:

```latex
\begin{thebibliography}{9}
\bibitem{ocpp} Open Charge Alliance. \emph{OCPP 1.6 Specification}, 2015.
\bibitem{armstrong} J. Armstrong. \emph{Programming Erlang}. Pragmatic Bookshelf, 2013.
\end{thebibliography}
```

Sopra i dieci, `biblatex` con `backend=biber` e `latexmk` che gestisce le passate.

Regola di sostanza: citare solo quello che si è davvero usato. Una bibliografia lunga in un
documento di progetto è sospetta, non autorevole.

## Riferimenti incrociati

`cleveref` con `\cref{sec:claim}` scrive "Section 7.1" da solo e resta corretto quando le
sezioni si spostano. Convenzione per le label: `sec:`, `fig:`, `tab:`, `lst:` come prefisso.

Mai scrivere a mano "come visto nella sezione 4": al primo riordino diventa falso.
