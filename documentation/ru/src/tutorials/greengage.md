# Greengage и очистка backend

Для пулов Greengage задайте явный полный сброс сессии:

```yaml
pools:
  analytics:
    # Добавьте обычные server_host, server_port и users.
    server_reset_query: |
      SET SESSION AUTHORIZATION DEFAULT;
      RESET ALL;
      DEALLOCATE ALL;
      CLOSE ALL;
      UNLISTEN *;
      SELECT pg_advisory_unlock_all();
      DISCARD PLANS;
      DISCARD SEQUENCES;
      DISCARD TEMP;
```

`general.server_reset_query` задаёт общее значение; настройка пула имеет
приоритет. Если один процесс обслуживает PostgreSQL и Greengage, оставьте
общее значение незаданным и настройте только пулы Greengage. Без эффективного
значения остаётся выборочная очистка: `RESET ROLE` и необходимые `RESET ALL`,
`DEALLOCATE ALL`, `CLOSE ALL`. pg_doorman отправляет `DISCARD ALL` только если
оператор явно задаёт его в конфигурации. Для PostgreSQL допустимо
`server_reset_query: DISCARD ALL`.

Настроенный запрос выполняется перед повторной выдачей использованного backend.
При необходимости pooler сначала отдельно выполняет `ROLLBACK`. В режиме
transaction очистка происходит после каждой транзакции, в session — при
отключении клиента. Проверка простаивающего backend также может потребовать
очистки перед checkout. Запрос обязан сбрасывать **всё состояние сессии**:
подготовленные выражения, курсоры, identity, GUC, временные объекты и сессионные
блокировки. За полноту SQL отвечает оператор: успешные `SELECT 1` или один
`RESET ALL` не выполняют этот контракт. Произвольный SQL не анализируется и
не переписывается.

Pooler полностью читает ответы, включая строки SELECT, и требует
`ReadyForQuery = Idle`. Ошибка SQL/транспорта, ответ на пустой запрос, COPY,
незавершённый обмен, таймаут или NOTICE о неподдерживаемой возможности
(`0A000`, Greengage `0AM01`) исключают backend из повторного использования.
Таймаут задаёт `general.connect_timeout`; обычные информационные NOTICE допустимы.
Локальный кэш prepared statements и снимок GUC сбрасываются после успешной
очистки. Полный reset уменьшает эффективность серверного prepared-кэша;
в transaction pooling клиентские выражения при необходимости подготавливаются
повторно. Пустые строки, строки из пробелов/точек с запятой, NUL и сочетание
custom reset с `cleanup_server_connections: false` отвергаются при загрузке.
Запрос только из комментариев приводит к закрытию backend при выполнении.
Отключение cleanup закрывает грязные соединения.

`RELOAD` создаёт новые пулы при изменении reset policy. Уже подключённые
клиенты могут продолжить работать со старым пулом и запросом; для полной смены
policy переподключите или дренируйте этих клиентов. Пустое значение пула не
отключает унаследованный запрос.

## Клиентский DISCARD ALL

Greengage 6.31.0 и 7.5.0 отвечают на `DISCARD ALL` сообщением `NOTICE 0AM01`,
затем очищают состояние координатора, включая prepared statements. Полная
операция **не отправляется на сегменты**. Успешный command tag не доказывает
очистку всего кластера. pg_doorman инвалидирует prepared-кэш координатора и
сохраняет необходимость cleanup; без настроенного reset такой backend закрывается, возможно с разрывом клиентского соединения.

SQL клиента остаётся SQL самого backend в simple и extended protocol. Если
клиент/драйвер использует `DISCARD ALL`, настройте его reset SQL отдельно:
для Greengage подходит приведённая выше последовательность. Cleanup защищает
следующего заёмщика соединения, но не эмулирует clusterwide DISCARD посреди
текущей клиентской сессии. Клиент может скрыть NOTICE через `client_min_messages`,
поэтому одного обнаружения NOTICE недостаточно. Для Greengage всегда задавайте
явный recipe, даже если `DISCARD ALL` внешне завершается успешно.

Основание: [документация Greengage](https://greengagedb.org/en/docs-gg/current/reference/sql_commands/discard.html)
и исходники релизов [6.31.0](https://github.com/GreengageDB/greengage/blob/6.31.0/src/backend/commands/discard.c)
и [7.5.0](https://github.com/GreengageDB/greengage/blob/7.5.0/src/backend/commands/discard.c).
В recipe добавлен `UNLISTEN *`: live-проверка обеих версий показала, что LISTEN
создаёт подписку координатора, которую восемь команд из документации не снимают.
Дополнение очищает подписки перед reuse; поддержка распределённой асинхронной
доставки уведомлений этим не гарантируется.

## Аудит служебного SQL и протокола

Таблица охватывает операции, которые pooler генерирует для backend. Проверка
исходников Greengage 6.31.0/7.5.0 и reset-сценариев не означает проверку всех
возможных клиентских нагрузок.

| Операция | Поддержка и настройка |
|---|---|
| ROLLBACK и выборочные RESET ROLE / RESET ALL / DEALLOCATE ALL / CLOSE ALL | Поддерживаются. Полный `server_reset_query` заменяет выборочную очистку. Неоднозначный клиентский tag RESET сохраняет необходимость очистки GUC. |
| Восстановление prepared после ошибок/оборванного batch | Тот же cleanup; при ошибке backend закрывается, устаревший кэш не используется. |
| Parse, Bind, Describe, Execute, Close, Sync, Flush | Стандартные операции протокола. Eviction отправляет Close/Sync, а не SQL DISCARD; SQL выражения принадлежит клиенту. |
| Настроенный `UNLISTEN *` | Снимает LISTEN-подписки координатора в обеих проверенных версиях; включён в полный recipe. |
| Проверка простаивающего backend: `;` | Поддерживается EmptyQueryResponse/ReadyForQuery; отдельная настройка для форка не нужна. |
| Клиентский pooler probe | Уже настраивается через `general.pooler_check_query`; ответ должен быть стабильным для кэширования. |
| StartupMessage | Protocol v3, user/database/application_name и `startup_parameters`. Уже есть уровни general/pool/auth_query. Неподдерживаемые GUC приводят к ошибке startup. |
| SET/RESET клиентских GUC при checkout | Управляется `sync_server_parameters`. После cleanup снимок нерепортируемых GUC забывается, чтобы восстановить, например, search_path. Настройки оператора из startup остаются reset defaults backend. |
| Поиск учётных данных | `auth_query.query` — SQL оператора с username в `$1`; встроенного запроса для замены нет. |
| Генерация конфигурации CLI | Читает `pg_shadow(usename, passwd)` и `pg_database(datname, datistemplate)`, существующие в обеих версиях. Доступ к каталогу паролей требует прав. |
| TLS, authentication, CancelRequest, Terminate | Протокольные операции, не reset SQL. Выбранную конфигурацию auth/TLS нужно проверять отдельно. |
| Отложенный BEGIN, COPY, fastpath | Пересылаемые операции клиента; дополнительного специфичного SQL нет. |
| Patroni fallback/proxy | REST и TCP; скрытых SQL probes `pg_is_in_recovery()` или read-only нет. Совместимость топологии Greengage этим не гарантируется. |

Выборочная очистка не отслеживает все временные объекты, advisory locks,
SQL PREPARE и эффекты функций. `RESET ROLE; RESET ALL` также не отменяет
`SET SESSION AUTHORIZATION`: полный recipe делает это явно. Используйте
полный reset для нагрузок с таким состоянием сессии.

SHA-256 verifier Greengage не является PostgreSQL SCRAM-SHA-256. Текущий
backend auth pg_doorman не поддерживает обычную cleartext-password
аутентификацию. Используйте проверенный поддерживаемый режим, например MD5;
новые механизмы аутентификации этим изменением не добавляются.

## Границы проверок

Регрессии на PostgreSQL проверяют повторную выдачу backend, session/transaction
mode, prepared reparse, GUC, rollback, reload, запросы reset со строками SELECT
и закрытие при ошибках. Wire fixtures проверяют неподдерживаемые NOTICE,
незавершённые ответы и отмену. Live reset проверки используют официальные
образы Greengage 6.31.0 и 7.5.0 с координатором и двумя сегментами.
TLS, HA/failover и распределённая отмена запросов в эти reset-проверки не входят.

Live-проверки: 20 сценариев (по 10 на версию), MD5 credentials backend и
доверенные локальные тестовые клиенты. Проверены тот же PID после клиентского
simple/extended DISCARD, скрытый NOTICE, pool override, prepared reparse и
закрытие после настоящих NOTICE-only/частично ошибочных reset. Временные
объекты проверены на координаторе **и обоих сегментах**.

Запуск регрессий из репозитория:

```sh
make test-bdd TAGS=@server-reset-query
make test-bdd TAGS=@client-session-reset-cleanup
cargo test --lib server::reset_tests
```
