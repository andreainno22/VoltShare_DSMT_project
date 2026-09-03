#!/usr/bin/env bash
# VoltShare — tutto il sistema in un terminale solo.
#
#   ./logs.sh                    i sette servizi, denoised
#   ./logs.sh coord1 coord2      solo quelli
#   VERBOSE=1 ./logs.sh          niente filtri, tutto grezzo
#
# Perché esiste, invece dei quattro pannelli del §5 di DEMO.md: seguire quattro
# terminali durante una presentazione è ingestibile, e la storia da raccontare è
# *una* — la prenotazione parte dal browser, il coordinatore decide, la stazione
# apre la sessione, Java la prezza. Su quattro riquadri quella storia è a pezzi;
# qui è una colonna in ordine di tempo.
#
# Tre cose la rendono leggibile, e senza di esse il flusso unico non lo sarebbe:
#
#   1. il timestamp di Docker (-t) portato a HH:MM:SS, così ogni riga è collocata
#      anche quando il messaggio non porta un'ora sua;
#   2. le intestazioni `=NOTICE REPORT==== ... ===` buttate via. Il logger di
#      Erlang stampa due righe per messaggio e la prima non dice niente che la
#      seconda non dica meglio: tenerle raddoppia il volume del pannello;
#   3. il nome del nodo colorato. Con sette servizi intrecciati il colore è
#      l'unica cosa che permette di seguire *un* attore senza rileggere.
#
# Il rumore tolto è solo quello periodico e privo di informazione: la
# ripubblicazione del leader ogni 30 s (vs_coord_bo), il ciclo di vita di Tomcat,
# e il ping di M0 se qualcuno lo riaccende. VERBOSE=1 rimette tutto.
set -u

cd "$(dirname "$0")/../../deploy"

# I colori sono per nodo, non per severità: durante la demo si segue un attore
# alla volta, e il livello di log lo dice già la parola. Ambra ai coordinatori
# perché sono loro che si guardano quando cade qualcosa.
exec docker compose --env-file .env.demo logs -f -t --tail=0 "$@" 2>&1 | awk -v verbose="${VERBOSE:-0}" '
BEGIN {
    R  = "\033[0m";  B = "\033[1m";  D = "\033[2m"
    col["coord1"]     = "\033[38;5;173m"
    col["coord2"]     = "\033[38;5;179m"
    col["coord3"]     = "\033[38;5;215m"
    col["station1"]   = "\033[38;5;72m"
    col["station2"]   = "\033[38;5;79m"
    col["backoffice"] = "\033[38;5;104m"
    col["mysql"]      = "\033[38;5;245m"
}

{
    bar = index($0, "| ")
    if (bar == 0) { print; next }

    svc = substr($0, 1, bar - 1)
    sub(/[ \t]+$/, "", svc)
    rest = substr($0, bar + 2)

    # Docker antepone un ISO-8601; ne teniamo solo l orario.
    tm = "        "
    if (rest ~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T/) {
        tm = substr(rest, 12, 8)
        z  = index(rest, "Z ")
        if (z > 0) rest = substr(rest, z + 2); else rest = ""
    }

    if (verbose != "1") {
        # 1. le intestazioni di report di Erlang: due righe per messaggio, la
        #    prima senza contenuto.
        if (rest ~ /^=(NOTICE|INFO|WARNING|ERROR|CRASH|SUPERVISOR|PROGRESS) REPORT====/) next
        # 2. il battito del ponte: vs_coord_bo ripubblica il leader ogni 30 s e
        #    il back office ri-spinge le sospensioni. E corretto e non e notizia.
        if (rest ~ /Coordinator leader is now/) next
        if (rest ~ /Re-sent [0-9]+ suspension/) next
        # 3. il ping di M0, se qualcuno rimette PING_TARGET nel compose.
        if (rest ~ /ping vs@.*pong from/) next
        # 4. il ciclo di vita del contenitore, non della nostra applicazione.
        if (rest ~ /org\.apache\.(catalina|coyote|jasper|tomcat)/) next
        if (rest ~ /\[Note\] \[Entrypoint\]|InnoDB:|\[Server\] \/usr\/sbin\/mysqld/) next
    }

    # Tomcat ripete data e ora, il livello e il thread: Docker le ha gia date.
    sub(/^[0-9][0-9]-[A-Za-z][a-z][a-z]-[0-9]+ [0-9:.]+ (INFO|WARNING|SEVERE|FINE) \[[^]]*\] /, "", rest)
    # e il nome pienamente qualificato della classe: bastano le ultime due parti.
    if (match(rest, /^([a-z][a-zA-Z0-9]*\.)+[A-Za-z0-9_$]+\.[a-zA-Z0-9_$]+ /)) {
        head = substr(rest, 1, RLENGTH - 1)
        tail = substr(rest, RLENGTH + 1)
        n = split(head, part, ".")
        rest = part[n-1] "." part[n] "  " tail
    }

    if (rest == "") next

    c = (svc in col) ? col[svc] : ""
    line = sprintf("%s%s%s  %s%-10s%s  %s", D, tm, R, c, svc, R, rest)

    # Le parole per cui si sta guardando il pannello. Evidenziarle non aggiunge
    # informazione: fa si che la si veda scorrere invece di doverla cercare.
    if (rest ~ /election|now the leader|QUORUM|quorum|rebuild|abdicat|standing by|nodedown|went down|suspend|expired|revok|SUSPENDED|NO_CLAIM|ALREADY_HELD|overstay/)
        line = B line R

    print line
    fflush()
}'
