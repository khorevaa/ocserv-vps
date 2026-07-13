[English](README.md) | [Русский](README_RU.md)

# ocserv-vps

Проверяемая Docker-сборка ocserv, приватная панель управления и самостоятельный установщик для чистого VPS с Debian или Ubuntu.

Образ VPN собирается из явно указанного релиза ocserv после проверки SHA-256 и GPG-подписи. UI разделён на непривилегированный web-контейнер и изолированный control-sidecar с минимальными правами. Панель публикует только Unix-сокет и открывается через локальный SSH-туннель — без публичного TCP-порта, nginx-прокси и доступа к Docker socket.

## Быстрая установка

Интерактивный запуск от root:

```bash
bash <(curl -Ls https://raw.githubusercontent.com/khorevaa/ocserv-vps/develop/install.sh)
```

Установщик следует модели 3x-ui: определяет ОС и архитектуру, ставит базовые зависимости, получает последний GitHub-релиз (или указанный тег), устанавливает команду `ocserv-vps` и запускает настройку.

Неинтерактивная установка:

```bash
curl -Ls https://raw.githubusercontent.com/khorevaa/ocserv-vps/develop/install.sh | \
  OCSERV_DOMAIN=vpn.example.com \
  OCSERV_ACME_EMAIL=admin@example.com \
  OCSERV_VPN_USERNAME=vpnuser \
  OCSERV_APPROVE_FIREWALL=1 \
  OCSERV_APPROVE_RESTART=1 \
  bash
```

Если stdin неинтерактивен и `OCSERV_DOMAIN` не задан, скрипт установит только менеджер. Продолжить можно командой `sudo ocserv-vps install`.

Установка конкретной версии менеджера:

```bash
bash <(curl -Ls https://raw.githubusercontent.com/khorevaa/ocserv-vps/develop/install.sh) v0.1.0
```

## Команды управления

Запуск `ocserv-vps` без аргументов открывает интерактивное меню. Основные команды:

```text
ocserv-vps install
ocserv-vps status
ocserv-vps add-user <имя>
ocserv-vps update
ocserv-vps rollback
ocserv-vps install-ui
ocserv-vps update-ui
ocserv-vps ui-access
ocserv-vps rotate-ui-access
ocserv-vps start|stop|restart
ocserv-vps logs
ocserv-vps update-manager [тег]
ocserv-vps uninstall [--purge-data]
```

Существующая установка Docker сохраняется; Docker Engine и Compose добавляются только при отсутствии. Bootstrap меняет firewall и может прервать SSH/VPN-сессии, поэтому требует явных подтверждений. Удаление сохраняет Docker и сертификаты Let's Encrypt; данные в `/opt/ocserv-vps` также сохраняются без флага `--purge-data`.

## Образы

- `ghcr.io/khorevaa/ocserv-vps-server:<версия-ocserv>`
- `ghcr.io/khorevaa/ocserv-vps-ui-web:<версия-ui>`
- `ghcr.io/khorevaa/ocserv-vps-ui-control:<версия-ui>`

Разворачиваются только явные version-теги. Перед активацией проверяются labels версии, исходного репозитория, компонента, ревизии и совместимости control-образа с ocserv.

## Структура репозитория

- `docker/` — подготовка проверенных исходников и сборка ocserv
- `ui/web/` — Go web/API и статический frontend
- `ui/control/` — изолированный Go-адаптер с `occtl` и `ocpasswd`
- `scripts/` — транзакционные операции жизненного цикла VPS
- `helpers/` — клиентские помощники SSH-туннеля к Unix-сокету
- `.github/workflows/` — тесты и публикация образов в GHCR

## Доступ к UI

UI не создаёт TCP-listener. После установки выполните на VPS:

```bash
sudo ocserv-vps ui-access
```

Команда покажет точный случайный hostname, текущий access secret и готовую команду SSH-туннеля к `/run/ocserv-ui-web/web.sock`. Секрет обменивается на непрозрачную серверную сессию и не помещается в URL.

## Сборка

Workflow `Publish ocserv image` принимает точные URL исходников и подписи, SHA-256, ключ/отпечаток подписи и digest базового образа. Workflow `Publish ocserv UI images` публикует согласованную пару UI/control для указанного образа ocserv. Для сборок включены provenance и SBOM.

## Лицензия

Автоматизация репозитория и UI распространяются по MIT. Опубликованные образы содержат ocserv и его исходники по GPLv2-or-later.
