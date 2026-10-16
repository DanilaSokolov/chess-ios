# Chess — iOS, iPadOS, macOS

Клиент на SwiftUI и учебные уроки по Metal. Сервисы на Go — в репозитории
[chess-backend](https://github.com/DanilaSokolov/chess-backend); `proto/` здесь — копия оттуда, менять контракт там.
Ниже общий README проекта: пути `server/…` и цели `make up`, `make test-db` относятся к chess-backend,
а содержимое `apple/` в этом репозитории лежит в корне (`apple/ChessApp` → `ChessApp`).

> **Не всё проверено сборкой (16.10.2026).** Последние изменения писались без компилятора:
> outbox писем в auth (`internal/auth/outbox.go`, миграция `005_mail_outbox.sql`) ещё не собирался и не
> прогонялся (`make -C server vet test test-db`). Поддержка iPhone Duo и раскладки в приложении собраны под
> macOS и iOS Simulator, но последние правки (повтор партии на `AnyLayout`, минимальный размер окна Mac,
> устаревший сгиб) — ещё нет. Подробности — в TODO.md.

Онлайн-шахматы: клиент на SwiftUI (iPhone + macOS) и авторитетный сервер на Go.
Три сервиса — отдельные процессы, у каждого своя база, если она вообще нужна:

| Сервис | Порт | Что делает | База |
|---|---|---|---|
| **game** (`cmd/server`) | :8080 | партии по WebSocket `/ws`; gRPC `GameInfo.Bootstrap` и health на том же порту | нет (спул на диске) |
| **auth** (`cmd/auth`) | :8081 | вход, регистрация, токены (gRPC) | auth-db (:5433) |
| **history** (`cmd/history`) | :8082 | история партий (gRPC) | history-db (:5434) |

REST нет: всё, кроме игрового канала, — gRPC.

```
                gRPC :8081 (вход, токены)
  app ───────────────────────────────────────► auth ──► auth-db
   │                                            ▲ GetPublicKeys: ключи для проверки JWT
   │  gRPC :8082 (ListGames, GetGame…)          │ (game и history проверяют токены сами)
   ├──────────────────────────────────► history ─┤──► history-db
   │                                       ▲     │
   │                       RecordGame      │     │
   │  WebSocket :8080/ws + gRPC :8080   (спул на │
   └────────────────────────────────► game ─────┘
                                       диске: ни одна партия не теряется)
```

```
apple/
  Chess.xcodeproj      multiplatform app (iOS 18+, macOS 15+)
  ChessApp/            SwiftUI-приложение, по папкам-функциям (синхронизируются с Xcode сами):
    App/               точка входа, выбор экрана, GameModel — связка экранов с ChessClient
    Auth/ Lobby/ Room/ Game/ Chat/   экраны
    Board/             доски 2D и 3D, общая палитра
  ChessCore/           Swift Package
    ChessCore          правила и генерация ходов (своя, проверена perft)
    ChessProto         сгенерировано из proto/ — не редактировать
    ChessNet           GameClient (URLSessionWebSocketTask + protobuf); gRPC-клиенты: AuthClient,
                       Bootstrap.fetch, ServerHealth (grpc-swift 2, транспорт Network.framework)
    ChessClient        состояние приложения и его правила без UI и сети: ClientState (события сервера → экран),
                       ConnectionManager (сокет, переподключение), AppSettings (что помнить между запусками),
                       AccountManager (аккаунт и токены; refresh-токен в Keychain)
    ChessModels        3D-фигуры из профилей (lathe/extrude), без RealityKit; export-pieces → apple/Models
  Models/              сгенерированные фигуры в USD (make models)
server/
  cmd/server           game: WebSocket + gRPC на одном порту :8080
  cmd/auth             auth: gRPC на :8081, свой Postgres
  cmd/history          history: gRPC на :8082, свой Postgres
  internal/history     хранение партий, постраничная выдача (keyset), сводка, проверка доступа
  internal/spool       outbox на диске: game отдаёт партии в history, не теряя их при сбоях
  internal/pgmigrate   миграции SQL (общие для auth и history)
  internal/svc         общий код запуска сервисов: окружение, логи, Postgres, gRPC-сервер
  Makefile             сборка, тесты, lint, запуск и Docker для бэкенда — `make -C server help`
  internal/auth        аккаунты, пароли (argon2id), refresh-токены с ротацией, миграции
  internal/accesstoken контракт токена между сервисами: JWT Ed25519, подпись (auth) и проверка (game)
  cmd/bot              бот со случайными ходами и шутками в чате — для проверки без второго устройства
  internal/gateway     WebSocket-сессии, маршрутизация сообщений
  internal/match       очередь по контролю времени
  internal/lobby       комнаты «игра с другом»: код, готовность, реванш со сменой цвета
  internal/chat        очистка текста, лимит частоты и история чата (общие для партий и комнат)
  internal/game        комната = горутина на партию, валидация через corentings/chess
  internal/pb          сгенерировано из proto/ (authpb — для auth)
proto/chess/v1/        контракт клиент ↔ game: chess.proto (WebSocket), game_info.proto (gRPC)
proto/chess/auth/v1/   контракт auth (gRPC)
proto/chess/history/v1/ контракт history (gRPC)
proto/grpc/health/v1/  стандартный health.proto (для клиента на Swift)
learn-metal/           учебные уроки по Metal и разбор, как сделаны 3D-фигуры (MODELS.md)
```

## Запуск

```bash
make up                             # game :8080, auth :8081, history :8082 и обе базы — в Docker
make -C server help                 # все команды бэкенда: тесты, lint, логи, psql, grpcurl, боты
make -C server load N=20            # N ботов с аккаунтами играют друг с другом — их партии пишутся в историю
cd server && go run ./cmd/bot -tc 3+2 -games 0   # соперник-бот
cd server && go run ./cmd/bot -room K7Q2MX -games 0   # бот садится в вашу комнату по коду
open apple/Chess.xcodeproj          # схема Chess, iPhone-симулятор или My Mac
```

Для запуска на реальном iPhone выберите Team в Signing & Capabilities и укажите в лобби адрес
`ws://<IP-мака>:8080/ws`. Для локальной сети `ws://` разрешён через `NSAllowsLocalNetworking`,
в продакшене нужен `wss://`.

## Стиль Swift

Код следует [Swift API Design Guidelines](https://www.swift.org/documentation/api-design-guidelines/)
и форматируется официальным `swift format` с настройками проекта из `apple/.swift-format`
(4 пробела, строка до 120 символов). `make lint` проверяет, `make format` исправляет.

**Версия Swift.** Компилятор 6.4, `swift-tools-version: 6.4`, режим языка 6: режима «6.4» не бывает, есть только 5, 6
и будущий 7. Правила конкурентности одинаковые в приложении (Xcode: Approachable Concurrency) и в пакетах
(`swiftSettings` в `Package.swift`), а фичи, которые станут обязательными в Swift 7, включены заранее:

| Фича | Что меняет |
|---|---|
| `NonisolatedNonsendingByDefault` | `nonisolated async` функция работает на актёре того, кто её вызвал; уйти в общий пул — `@concurrent` |
| `InferIsolatedConformances` | `@MainActor`-тип соответствует протоколу только на главном актёре (`: @MainActor Lesson`) |
| `ExistentialAny` | протокол как тип пишется `any MTLDevice`, а не `MTLDevice` |
| `MemberImportVisibility` | методы модуля видны только в файлах, где он импортирован (`import os`, `import SwiftProtobuf`) |

Миграция кода: `swift package migrate --to-feature <фичи>`. Тесты она не трогает, их правят по сообщениям компилятора.

Ловушка, найденная по Instruments: аргументы `async let` вычисляются уже в дочерней задаче. Если среди них
есть свойство главного актёра (`settings.webSocketURL`), задача ждёт главный поток, и параллельности нет.
Значение читается в локальную константу до `async let` (см. `GameModel.start()`).

## Запуск приложения и версии

При старте приложение показывает экран загрузки и вызывает `chess.v1.GameInfo/Bootstrap` (gRPC на том же
адресе, что и WebSocket) с версией приложения, версией протокола и языком. Статус версии решает сервер:

| Статус | Когда | Что видит игрок |
|---|---|---|
| `SUPPORTED` | версия ≥ `CHESS_LATEST_CLIENT_VERSION` | ничего |
| `OUTDATED` | `CHESS_MIN_CLIENT_VERSION` ≤ версия < последней | играет, в лобби «Доступна новая версия» |
| `UNSUPPORTED` | ниже минимальной, в `CHESS_BLOCKED_CLIENT_VERSIONS`, неразборчивая или другой протокол | экран «Нужно обновление» |

`CHESS_BLOCKED_CLIENT_VERSIONS` (`1.3.2,1.4.0`) отключает отдельные релизы с серьёзной ошибкой, не поднимая
минимальную версию для всех.

`CHESS_UPDATE_URL` — ссылка на App Store, `CHESS_TIME_CONTROLS` — контроли времени в лобби (`1+0,3+2,…`).
Если сервер не ответил за 3 с, приложение берёт прошлый ответ (только для той же версии приложения) и открывает лобби.
На экране загрузки же переподключается в незаконченную партию или комнату и готовит 3D-фигуры.

## Аккаунты (auth)

Отдельный процесс `cmd/auth`, gRPC-сервис `chess.auth.v1.AuthService` (контракт и коды ошибок —
`proto/chess/auth/v1/auth.proto`). Адрес для приложения game отдаёт в Bootstrap (`CHESS_AUTH_URL`),
поэтому auth можно переносить без нового релиза приложения.

- **Вход:** анонимно (аккаунт на устройство, имя `anonim` + 6 символов id) или логин + пароль.
  Пароли — argon2id (19 MiB, 2 прохода); ошибка входа одинакова для неверного логина и пароля,
  и время ответа тоже: по нему не узнать, кто зарегистрирован. Лимиты попыток по адресу и логину.
- **Access token:** JWT на 15 минут, подпись Ed25519, в нём id сессии (`sid`). Проверка в два шага
  (`accesstoken.Authenticator`):
  1. **Подпись** — сам сервис, открытым ключом из `GetPublicKeys`: алгоритм только EdDSA, ключ по `kid`,
     `iss`, `aud`, `exp`. Сеть не нужна.
  2. **Сессия** — game при подключении и history на запросах спрашивают auth `CheckSession`: не вышел ли игрок,
     не отозвана ли сессия после кражи, не забанен ли. Ответ кэшируется на минуту (`CHESS_SESSION_CHECK_TTL`,
     `HISTORY_SESSION_CHECK_TTL`). Auth не отвечает — пускаем по подписи (fail open): игра не останавливается,
     отзыв догонит, когда auth вернётся. Идущие партии auth не трогает.

  Итог: после «Выйти», кражи refresh-токена или бана доступ пропадает в пределах минуты, а не 15.
- **Блокировка после неверных паролей** ([lockout.go](server/internal/auth/lockout.go)):
  3 подряд → вход по логину закрыт на 15 минут; после этого ещё 5 подряд → закрыт бессрочно;
  верный пароль обнуляет счётчик. Ответ — `PERMISSION_DENIED` с reason `TEMPORARILY_LOCKED`
  (сколько ждать — в `RetryInfo` и в metadata `retry_after_seconds`) или `ACCOUNT_LOCKED`.
  Разблокировка не нужна по расписанию: в базе хранится `locked_until`, и вход сравнивает его с текущим временем.
  Блокировка — не бан: уже вошедшие устройства владельца продолжают играть, иначе любой, кто знает логин,
  мог бы выкинуть владельца отовсюду. Попытки во время блокировки не считаются, а параллельные попытки
  выстраиваются в очередь блокировкой строки (`FOR UPDATE`), так что мимо счётчика не проскочить.
  `make -C server locks` — кто заблокирован, `make -C server unlock LOGIN=alice` — снять.
- **Почта и сброс пароля** ([codes.go](server/internal/auth/codes.go), [email_service.go](server/internal/auth/email_service.go)).
  Почта необязательна: при регистрации или позже (лобби → «Почта и восстановление пароля»), подтверждается кодом.
  «Забыли пароль?» шлёт 6-значный код на подтверждённую почту; ответ одинаковый, есть такой логин или нет
  (и письмо уходит в фоне, чтобы не выдать это и по времени). Код живёт 30 минут, в базе только хеш,
  5 неверных попыток — и код мёртв; не больше одного кода в минуту и пяти в час на аккаунт.
  Новый пароль снимает блокировку и закрывает все прежние сессии (если сброс из-за взлома — взломщик тоже выходит).
  **Письма идут через outbox** ([outbox.go](server/internal/auth/outbox.go)): код и письмо с ним пишутся
  в `mail_outbox` одной транзакцией, вызов отвечает, не дожидаясь SMTP. Фоновый воркер в каждой копии auth
  забирает письма через `FOR UPDATE SKIP LOCKED` (одно письмо не уйдёт дважды из двух копий), при сбое повторяет
  с паузами 10 с → 20 с → … → 10 мин (половина паузы случайна), до 8 попыток. Письмо с истёкшим кодом
  не отправляется никогда; новый код отменяет ещё не ушедшее письмо со старым. Текст письма (в нём код) стирается
  сразу после отправки или отказа, в логах его нет. Очередь: `make -C server mail`.
  Письма в разработке ловит **Mailpit**: http://localhost:8025 — все письма видны там, наружу ничего не уходит.
  В продакшене: `AUTH_SMTP_ADDR`, `AUTH_SMTP_USERNAME`, `AUTH_SMTP_PASSWORD`, `AUTH_MAIL_FROM` от почтового провайдера.
- **Лимит регистраций** с одного адреса: `AUTH_SIGNUP_BURST` сразу, дальше по одной раз в `AUTH_SIGNUP_REFILL`
  (по умолчанию 10, затем раз в минуту; в docker-compose для разработки — 100 и раз в секунду, ради ботов и тестов).
- **Бан:** `UPDATE users SET banned_at = now() WHERE id = '…'` в auth-db (`make -C server psql-auth`).
  Забаненный не войдёт и не обновит токен (`PERMISSION_DENIED`, reason `BANNED`); об этом узнаёт только тот,
  кто ввёл верный пароль.
- **Refresh token:** 60 дней, в базе только SHA-256. Каждый работает один раз: `Refresh` выдаёт новый.
  Повторное предъявление старого значит кражу — отзывается вся цепочка. Приложение хранит его в Keychain
  и не допускает двух одновременных обновлений (иначе второе само выглядело бы как кража).
- **Ошибки:** gRPC-код + `google.rpc.ErrorInfo` (domain `auth.chess`, reason `LOGIN_TAKEN`, `BAD_CREDENTIALS`…);
  слова на нужном языке выбирает приложение.

Посмотреть API руками (у обоих серверов включён reflection):

```bash
docker run --rm --network chess_default fullstorydev/grpcurl -plaintext auth:8081 list
docker run --rm --network chess_default fullstorydev/grpcurl -plaintext -d '{}' auth:8081 chess.auth.v1.AuthService/SignUpAnonymously
docker run --rm --network chess_default fullstorydev/grpcurl -plaintext -d '{"client_version":"0.1","protocol_version":4}' server:8080 chess.v1.GameInfo/Bootstrap
```

Game слушает WebSocket и gRPC на одном порту: WebSocket — это HTTP/1.1 с Upgrade, gRPC — HTTP/2 без TLS (h2c);
`net/http` различает их по первым байтам соединения. Игроку нужно знать один адрес.

## История партий (history)

Когда партия заканчивается, game собирает запись (игроки, контроль, результат, все ходы в UCI, время начала и конца)
и отдаёт её в history. Партии только между гостями (ботами) не сохраняются: их некому посмотреть.

**Доставка без потерь — outbox на диске** (`internal/spool`). Game сначала надёжно пишет партию файлом
(временный файл → `fsync` → `rename` → `fsync` каталога), потом фоновая горутина отправляет `RecordGame`
и удаляет файл только после ответа. History недоступен — файлы ждут и уходят с паузами 1 с → 2 с → … → 1 мин;
game перезапустился — новые процессы отправляют оставшееся. History сохраняет партию один раз, сколько бы раз она
ни пришла (`ON CONFLICT DO NOTHING`). Посмотреть очередь: `make -C server spool`.

**Доступ.** `RecordGame` — только game, по общему секрету `HISTORY_INTERNAL_TOKEN` в метаданных `x-internal-token`.
Остальное — игрок с access token от auth (`authorization: Bearer …`); history проверяет его ключами auth, как game,
и показывает только свои партии: чужая партия и несуществующая отвечают одинаково (`NOT_FOUND`).

**Чтение.** `ListGames` — партии с вашей стороны (цвет, соперник, победа/поражение), страницами по ключу
`(finished_at, id)`: страницы не пропускают и не повторяют партии, даже если между запросами доиграна новая.
`GetSummary` — партии, победы, поражения, ничьи. `GetGame` — все ходы; в приложении партию можно пролистать
по ходам (лобби → «История партий»).

## Локализация

Строки в коде английские: `Text("Ready")`, `String(localized: "Ready")`. Переводы лежат в String Catalog:
`apple/ChessApp/Localizable.xcstrings` (интерфейс) и `apple/ChessCore/Sources/ChessClient/Resources/Localizable.xcstrings`
(ошибки и состояния, в коде с `bundle: .module`). Открываются в Xcode таблицей: ключ → перевод на каждый язык.
Язык выбирает система по настройкам устройства. Новый язык: в каталоге «+» → язык, затем перевести строки.
Строки, которые не переводятся (цифры, «2D», ходы), помечены `Text(verbatim:)`.

Приложение сообщает серверу язык своего интерфейса в `Hello.language` (как `Accept-Language`).
Сервер хранит его у игрока и передаёт соперникам (`GameStarted.opponent_language`, `RoomMember.language`),
чтобы бот шутил на их языке. Ошибки сервер шлёт кодами, текст по коду выбирает приложение.

## Производительность и нагрев

**Метки для Instruments** (`apple/ChessApp/Performance/Signposts.swift`). Приложение размечает свою работу
signpost-интервалами в категории Points of Interest, их показывает любой шаблон Instruments:

| Интервал | Что это |
|---|---|
| Launch → Bootstrap, Reconnect, Preload 3D | сплэш по шагам |
| Piece mesh, Wood texture | разовая подготовка 3D, дальше из кэша |
| Pieces | обновление фигур 3D-доски после хода: сколько сдвинуто, снято, добавлено |
| Move | от отправки хода до ответа сервера: задержка, которую чувствует игрок |
| Thermal state (событие) | смена нагрева или Low Power Mode |

```bash
xcrun xctrace record --template 'Time Profiler' --time-limit 30s --output chess.trace --launch -- .build/xcode/Build/Products/Debug/Chess.app
xcrun xctrace record --template 'Time Profiler' --device <UDID симулятора> --attach Chess --time-limit 30s --output sim.trace
```

Для `--launch` указывайте сборку из `.build/xcode`: macOS открывает приложение по bundle id и может запустить
другую копию с тем же id. Замеры на Mac (Apple Silicon): Launch ≈ 0,6 с, из них Preload 3D ≈ 0,23 с,
причём первый меш ≈ 0,13 с (прогрев RealityKit), остальные по 2–3 мс. Прогрев идёт, пока ждём ответа сервера.

Пример оптимизации по этим меткам. Раньше 3D-доска на каждом ходу выбрасывала все 32 фигуры и строила их заново:
Pieces ≈ 7–11 мс на симуляторе. Теперь `PieceChanges` сравнивает две позиции по клеткам и трогает только
изменившиеся (рокировка и взятие на проходе получаются сами, без знания правил): Pieces ≈ 0,1–0,2 мс.
Первый ход всё ещё ≈ 10 мс, это RealityKit запускает систему анимаций при первом `move(to:)`.

**Нагрев** (`PowerMonitor`, `RenderQuality`). Горячий телефон сам снижает частоты (thermal throttling),
и кадры начинают опаздывать. Поэтому 3D-доска упрощается сама, а вместо кубика в меню появляется термометр:

| Состояние | Качество | Что выключается |
|---|---|---|
| nominal, fair | full | ничего |
| serious или Low Power Mode | reduced | тени, фигуры ≤ 24 граней |
| critical | minimal | ещё лак, фигуры ≤ 12 граней |

Проверить на iPhone: Xcode → Devices and Simulators → Device Conditions → Thermal State. Симулятор не греется,
поэтому в debug-сборке есть аргументы запуска `-simulateThermalState serious|critical` и `-simulateLowPowerMode YES`:

```bash
xcrun simctl launch --terminate-running-process booted dev.chess.Chess -simulateThermalState critical
```

## Тесты

```bash
make test            # go vet + go test -race, swift test (perft, протокол)
make test-db         # auth и history на настоящем Postgres (поднимает базы в Docker) и по настоящему gRPC (bufconn)
make test-live       # сетевой слой приложения против запущенных сервисов (сначала make up)
```

Live-тесты (`ChessNetTests/LiveServerTests.swift`, `GRPCLiveTests.swift`) подключаются к запущенным сервисам:
WebSocket-партия, Bootstrap и Health у game, вход/обновление/повтор токена у auth, история с настоящим токеном.
С `CHESS_BOT=1` и ботом на `-tc 9+9` Swift-клиент играет случайными ходами из ChessCore,
а сервер проверяет их независимой библиотекой: так ловятся расхождения в правилах.

## Как устроена партия

- **Часы** ведёт сервер. Время хода списывается при каждом ходе, после хода добавляется инкремент.
  Таймер комнаты фиксирует флаг. Если у соперника нет материала для мата, засчитывается ничья (правила FIDE).
  Часы белых стартуют сразу. Клиент только отсчитывает время между сообщениями.
- **Ничья**: `OfferDraw` — это предложение, а если соперник уже предложил, то согласие. Ход вместо ответа отклоняет предложение.
- **Реконнект**: в `Welcome` приходит `resume_token`. Повторный `Hello` с ним возвращает в ту же партию
  через `GameSnapshot`. Пока игрока нет, соперник получает `OpponentStatus`, а часы продолжают идти.
  Если игрок не вернётся за `CHESS_RECONNECT_GRACE` (по умолчанию 60s), засчитывается поражение.
  Новое соединение с тем же токеном вытесняет старое. Если партия закончилась, пока игрок был офлайн,
  после реконнекта `GameOver` приходит повторно (клиенты отбрасывают дубли).
- **Чат**: `SendChat` → `ChatMessage` обоим игрокам. Автора (цвет) ставит сервер, клиент его не присылает.
  Сервер склеивает пробелы и переносы, вырезает управляющие и невидимые символы (bidi, zero-width),
  отказывает в пустом тексте и тексте длиннее 200 символов, ограничивает частоту: 5 сообщений сразу,
  потом одно в 2 с (лимит у игрока, переподключение его не сбрасывает). Последние 100 сообщений
  приходят в `GameSnapshot` после реконнекта. Чат живёт, пока идёт партия. В приложении соперника
  можно скрыть, но только на своём устройстве. Текст сообщений сервер не пишет в лог.
- **Комнаты** (игра с другом): `CreateRoom` даёт код из 6 символов без похожих букв и цифр (0/O, 1/I/L),
  второй игрок входит по нему (`JoinRoom`, регистр не важен). В комнате двое. Когда оба прислали
  `SetReady`, идёт отсчёт `CHESS_ROOM_COUNTDOWN` (3 с, в `RoomState.starts_in_ms`), и партия начинается, а после неё оба возвращаются в комнату. В первой партии создатель
  играет выбранным цветом, дальше цвета меняются. Изменения приходят в `RoomState` (полное состояние),
  чат комнаты (`SendChat.room_code`) работает до, во время и после партий. Если связь оборвалась,
  место держится `CHESS_RECONNECT_GRACE`, во время партии действует её собственная отсрочка.
  Пока игрок в комнате, искать игру он не может. Попытки входа ограничены (5 сразу, потом одна в 2 с),
  чтобы коды нельзя было подобрать перебором.
- **Сторона**: в `FindGame.color` можно указать предпочтение. Игроки сводятся только при совместимых предпочтениях.

## Гонки

```bash
cd server && go test -race -count=20 -shuffle=on ./...
cd apple/ChessCore && CHESS_SERVER_URL=ws://localhost:8080/ws CHESS_BOT=1 swift test --sanitize=thread
```

`internal/gateway/race_test.go` содержит детерминированные тесты найденных гонок и `TestStress`.
В нём 60 игроков одновременно ходят, отключаются, переподключаются, открывают второе соединение
поверх живого, предлагают ничьи и сдаются. Проверяется, что каждая партия завершается и оба игрока
видят один и тот же результат. Комнаты тестируются в `testing/synctest` (виртуальное время).

На macOS много прогонов `TestStress` подряд забивают loopback-сокеты (`TIME_WAIT`), и `connect`
начинает отваливаться по таймауту. Это ограничение окружения, а не сервера: дамп горутин при этом пустой.

## Протокол

После изменения `proto/chess/v1/chess.proto` выполните `make proto`. Он соберёт `protoc-gen-swift`
в `.tools/` при первом запуске. Нужны `protoc` и `protoc-gen-go`.

Ход отправляется с номером полухода `ply` (1 — первый ход белых). Сервер принимает ход только при
`ply == сыграно + 1`, поэтому повторная отправка безопасна. Клиент показывает свой ход сразу,
а позиция из `MoveMade` / `MoveRejected` от сервера всегда считается истинной.

## Этапы

- [x] 1. Гости, matchmaking, валидация ходов, конец партии (мат/пат/ничьи/сдача/отключение)
- [x] 2. Часы на сервере, предложение ничьей, реконнект со `Snapshot`, выбор стороны, индикатор сервера
- [x] Перетаскивание фигур
- [x] 3a. Сервис auth (gRPC): анонимный вход и логин/пароль, JWT + refresh, свой Postgres
- [x] 3b. История партий: сервис history (gRPC), доставка через outbox, экран «История» с просмотром по ходам
- [ ] 3c. Sign in with Apple
- [x] Чат партии, игра с другом через комнату по коду
- [x] Доска 2D / 3D (RealityKit), переключатель в партии, перетаскивание фигур в обоих режимах
- [ ] 4. Рейтинг Glicko-2, Game Center
- [ ] 5. Деплой: сервисы + Postgres
