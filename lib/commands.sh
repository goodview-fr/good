#!/usr/bin/env bash
# Command registry, help, and dispatch

# Format: aliases (comma-separated)::handler::help text
GOOD_COMMAND_REGISTRY=(
    "c,commit::cmd_commit::Stage tout + génère message AI + commit"
    "p,push::cmd_push::Commit si besoin + push GitHub (crée le repo si absent)"
    "s,sync::cmd_sync::Commit + fetch + rebase + push"
    "r,resolve::cmd_resolve::Résout les conflits git avec l'IA"
    "ai,do::cmd_ai::Instruction NL → lancer, diagnostiquer ou modifier (IA)"
    "dog::cmd_dog::Assistant interactif Ollama (stream, file d'attente)"
    "dev::cmd_dev::Gérer le serveur de dev (stop|status|start)"
    "i,init::cmd_init::Initialise git + lie le dépôt à un projet Goodview (OAuth)"
    "info::cmd_info::Affiche la liaison Goodview du dépôt local"
    "unlink::cmd_unlink::Supprime la liaison Goodview (.good/config.json)"
    "update,u::cmd_update::Met à jour good CLI (+ contexte Goodview si lié)"
    "l,log::cmd_log::Log git graphique (20 derniers commits)"
    "st,status::cmd_status::Status court + derniers commits"
    "health::cmd_health::Santé du projet (git, dev, outils)"
    "stats::cmd_stats::Vue dev — activité good sur la période"
    "report::cmd_report::Vue manager — synthèse + sync Goodview"
    "telemetry::cmd_telemetry::Gérer le suivi d'activité (on|off|sync|status)"
)

cmd_version() {
    echo "good v${VERSION}"
}

cmd_help() {
    local entry aliases help_text
    echo "good - Git + Goodview (IA locale via Ollama)"
    echo ""
    for entry in "${GOOD_COMMAND_REGISTRY[@]}"; do
        aliases="${entry%%::*}"
        help_text="${entry##*::}"
        printf "  %-12s %s\n" "${aliases//,/, }" "$help_text"
    done
    cat <<'EOF'

  Options globales : -y, --yes (skip confirmations)

  good dog [-p "…"]                        assistant interactif Ollama
  good ai start|diagnose|edit|stop|status  sous-commandes explicites
  good dev stop|status|start               cycle serveur de dev
  good health|stats|report                 suivi santé et activité
  good telemetry on|off|sync|status      télémétrie et sync Goodview
  good update --force --deps               options de mise à jour
  good p|s --no-commit                     push/sync sans auto-commit
  Syntaxe « # message » : good '#' 'lance le projet'

Variables d'environnement :
  GOODVIEW_URL  URL du site (défaut: https://www.goodview.fr)
  GOODVIEW_API  URL de l'API (défaut: GOODVIEW_URL/api)
EOF
}

_good_dispatch() {
    local cmd="$1"
    shift

    case "$cmd" in
        c|commit)   cmd_commit "$@" ;;
        p|push)     cmd_push "$@" ;;
        s|sync)     cmd_sync "$@" ;;
        r|resolve)  cmd_resolve "$@" ;;
        ai|do)      cmd_ai "$@" ;;
        dog)        cmd_dog "$@" ;;
        dev)        cmd_dev "$@" ;;
        i|init)     cmd_init "$@" ;;
        info)       cmd_info "$@" ;;
        unlink)     cmd_unlink "$@" ;;
        update|u)   cmd_update "$@" ;;
        l|log)      cmd_log "$@" ;;
        st|status)  cmd_status "$@" ;;
        health)     cmd_health "$@" ;;
        stats)      cmd_stats "$@" ;;
        report)     cmd_report "$@" ;;
        telemetry)  cmd_telemetry "$@" ;;
        help|-h|--help) cmd_help ;;
        --version|-v)   cmd_version ;;
        \#)           cmd_ai "$@" ;;
        *)
            echo "Commande inconnue: $cmd"
            cmd_help
            exit 1
            ;;
    esac
}

_good_parse_global_flags() {
    # shellcheck disable=SC2034
    GOOD_YES=0
    while [ $# -gt 0 ]; do
        case "$1" in
            -y|--yes) GOOD_YES=1; shift ;;
            *) break ;;
        esac
    done
    # shellcheck disable=SC2034
    REMAINING_ARGS=("$@")
}
