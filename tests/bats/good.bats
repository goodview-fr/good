#!/usr/bin/env bash
# Bats tests for good CLI dispatch and git composition

GOOD_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
GOOD="$GOOD_ROOT/good"

setup() {
    export PATH="$GOOD_ROOT:$PATH"
    TEST_DIR="$(mktemp -d)"
    cd "$TEST_DIR" || return 1
    git init -q
    git config user.email "test@example.com"
    git config user.name "Test User"
    echo "hello" > file.txt
    git add file.txt
    git commit -q -m "init"
}

teardown() {
    rm -rf "$TEST_DIR"
}

@test "good --version affiche la version" {
    run "$GOOD" --version
    [ "$status" -eq 0 ]
    [[ "$output" == good\ v* ]]
}

@test "good help liste les commandes principales" {
    run "$GOOD" help
    [ "$status" -eq 0 ]
    [[ "$output" == *"commit"* ]]
    [[ "$output" == *"dev"* ]]
    [[ "$output" == *"update, u"* ]]
}

@test "commande inconnue retourne erreur" {
    run "$GOOD" unknown-cmd
    [ "$status" -eq 1 ]
    [[ "$output" == *"inconnue"* ]]
}

@test "alias u appelle update help" {
    run "$GOOD" u --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"Usage: good update"* ]]
}

@test "good health affiche le score" {
    run "$GOOD" health
    [ "$status" -eq 0 ]
    [[ "$output" == *"Score"* ]]
}

@test "good stats sans activité" {
    run "$GOOD" stats --days 7
    [ "$status" -eq 0 ]
    [[ "$output" == *"Activité good"* ]]
}

@test "good telemetry status" {
    run "$GOOD" telemetry status
    [ "$status" -eq 0 ]
    [[ "$output" == *"Télémétrie"* ]]
}

@test "push annulé si commit refusé" {
    echo "change" >> file.txt
    run bash -c "printf 'n\n' | '$GOOD' p"
    [ "$status" -eq 1 ]
    [[ "$output" == *"Push annulé"* ]]
    run "$GOOD" stats --days 1
    [[ "$output" == *"push"* ]] || [[ "$output" == *"0"* ]]
}

@test "commit annulé seul exit 0" {
    echo "change2" >> file.txt
    run bash -c "printf 'n\n' | '$GOOD' c"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Commit annulé"* ]]
}

@test "good dev status sans pid" {
    run "$GOOD" dev status
    [ "$status" -eq 0 ]
    [[ "$output" == *"PID"* ]]
}

@test "good ai sans argument affiche usage" {
    run "$GOOD" ai
    [ "$status" -eq 1 ]
    [[ "$output" == *"Usage: good ai"* ]]
    [[ "$output" == *"start|diagnose|edit"* ]]
}
