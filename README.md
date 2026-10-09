# Nginx Proxy Manager aktualisieren

Das Skript aktualisiert den Nginx Proxy Manager aus der `compose.yml`. Vor dem
Containerwechsel sichert es `data`, `letsencrypt` und die Compose-Datei im
Verzeichnis `backups`.

## Voraussetzungen

- Linux mit Docker und Docker Compose
- Das Skript liegt neben der `compose.yml`
- Der ausführende Benutzer darf Docker verwenden und die Daten lesen

## Ausführen

Beim ersten Mal ausführbar machen:

```bash
chmod +x nginxpm_docker_update.sh
```

Update starten:

```bash
sudo ./nginxpm_docker_update.sh
```

Wenn kein neues Image vorhanden ist, wird der laufende Container nicht neu
gestartet. Backups werden standardmäßig nach 30 Tagen gelöscht. Der externe
Log-Mount wird nicht gesichert.

Ein Update kann auch ohne neues Image erzwungen werden:

```bash
sudo FORCE_UPDATE=1 ./nginxpm_docker_update.sh
```

## Regelmäßig per Cron ausführen

Beispiel für ein Update jeden Sonntag um 04:00 Uhr:

```cron
0 4 * * 0 cd /pfad/zu/nginxpm && ./nginxpm_docker_update.sh >> update.log 2>&1
```

Dabei `/pfad/zu/nginxpm` durch den tatsächlichen Projektpfad ersetzen. Der
Cron-Benutzer benötigt Zugriff auf Docker und die Nginx-Proxy-Manager-Daten.