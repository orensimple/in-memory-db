#Tarantool

## About
Была выбрана таблица users и запрос поиска пользователей по частичному совпадению имени и фамилии.

Для tarantool были написана lua-процедуры для поиска пользователей по префиксу имени/фамилии. 
Также был создан составной индекс по first_name и second_name для поиска пользователей по нему.

```lua
function start()
    -- таблица "пользователи"
    box.schema.space.create('users', { if_not_exists = true })

    -- индексы для поиска по таблице
    box.space.users:create_index('primary', { type = "TREE", unique = true, parts = { 1, 'unsigned' }, if_not_exists = true })
    box.space.users:create_index('first_second_name_idx', { type = 'TREE', unique = false, parts = {4, 'string', 5, 'string' }, if_not_exists = true })
    box.space.users:create_index('first_name_idx', { type = 'TREE', unique = false, parts = { 4, 'string' }, if_not_exists = true })
    box.space.users:create_index('second_name_idx', { type = 'TREE', unique = false, parts = { 5, 'string' }, if_not_exists = true })
end

-- procedure for search by first name prefix AND second name prefix
-- Param: prefix_first_name - prefix for searching first name by like '%first_name'
-- Param: prefix_second_name - prefix for searching second name by like '%second_name'
-- Param: size - max count of entries in response
function search_by_first_second_name(prefix_first_name, prefix_second_name, size)
    local count = 0
    local result = {}
    for _, tuple in box.space.users.index.first_second_name_idx:pairs(prefix_first_name, { iterator = 'GE' }) do
        if string.startswith(tuple[4], prefix_first_name, 1, -1) and string.startswith(tuple[5], prefix_second_name, 1, -1) then
            table.insert(result, tuple)
            count = count + 1
            if count >= size then
                return result
            end
        end
    end
    return result
end

-- procedure for search by first name prefix
-- Param: prefix - prefix for searching first name by like '%first_name'
function search_by_first_name(prefix)
    local result = {}
    for _, tuple in box.space.users.index.first_name_idx:pairs({ prefix }, { iterator = 'GE' }) do
        if string.startswith(tuple[4], prefix, 1, -1) then
            table.insert(result, tuple)
        end
    end
    return result
end

-- procedure for search by second name prefix
-- Param: prefix - prefix for searching first name by like '%second_name'
function search_by_second_name(prefix)
    local result = {}
    for _, tuple in box.space.users.index.second_name_idx:pairs({ prefix }, { iterator = 'GE' }) do
        if string.startswith(tuple[5], prefix, 1, -1) then
            table.insert(result, tuple)
        end
    end
    return result
end
```

Tarantool запускается с помощью официального докер-образа (https://github.com/tarantool/docker). Запустить tarantool и репликацию в Kubernetes не хватило терпения.
Кластер mysql с настроенной репликацией пришлось создать заново, так как ранее тесты проводил в Kubernetes

Репликатор собрать свой докер образ с ним (докер-образ размещен на dockerhub: [Docker](https://hub.docker.com/r/orensimple/trade-core-app). 
При сборке образа использовалась инструкция из официального репозитория репликатора [MySQL slave replication daemon for Tarantool](https://github.com/tarantool/mysql-tarantool-replication)

```dockerfile
FROM centos:7

# install git, make and dependencies
RUN yum update -y && \
    yum -y install ncurses-devel git make cmake gcc gcc-c++ boost boost-devel mysql-devel mysql-lib

# clone replicator git repository
RUN git clone https://github.com/tarantool/mysql-tarantool-replication.git

# update git submodules and build replicator
RUN cd mysql-tarantool-replication && \
    git submodule update --init --recursive  && \
    cmake . && \
    make && \
    cp replicatord /usr/local/sbin/replicatord

# copy replicator config files
COPY ./replicatord.service /etc/systemd/system
COPY ./replicatord.yml /usr/local/etc/replicatord.yml
COPY ./init.sh /

CMD ["/init.sh"]
```

Итоговый docker-compose файл приведен ниже:

```yaml
version: '3'
services:
  mysql_master:
    image: mysql:5.7
    container_name: "mysql_master"
    env_file:
      - ./master/mysql_master.env
    restart: "no"
    ports:
      - 3306:3306
    volumes:
      - ./master/conf/mysql.conf.cnf:/etc/mysql/conf.d/mysql.conf.cnf
      - ./master/data:/var/lib/mysql
    networks:
      - test_tarantul

  tarantool:
    image: tarantool/tarantool:1.10.2
    container_name: "tarantool"
    networks:
      - test_tarantul
    ports:
      - "3301:3301"
    volumes:
      - ./tarantool/conf/init.lua:/opt/tarantool/init.lua
      - ./tarantool/conf/config.yml:/etc/tarantool/config.yml
      - ./tarantool/data:/var/lib/tarantool

  replicator:
    image: avpgenium/mysql-tarantool-replication:latest
    container_name: "mysql-tarantool-replication"
    networks:
      - test_tarantul

networks:
  test_tarantul:
```

Краткая инструкция по запуску:
- Запустить контейнер с mysql master-узлом.
- На mysql master-узле создать пользователя для репликации:
```sql
CREATE USER <username>@'<host>' IDENTIFIED BY '<password>';

GRANT REPLICATION CLIENT ON *.* TO 'mydb_slave_user'@'%' IDENTIFIED BY 'mydb_slave_pwd';
GRANT REPLICATION SLAVE ON *.* TO 'mydb_slave_user'@'%' IDENTIFIED BY 'mydb_slave_pwd';
GRANT SELECT ON *.* TO 'mydb_slave_user'@'%' IDENTIFIED BY 'mydb_slave_pwd';

FLUSH PRIVILEGES
```
- запускаем tarantool 
- запускаем replicator

### App

Для подключения к tarantool бекенда социальной сети и работы с ним использовался
[Client in Go for Tarantool 1.6+](https://github.com/tarantool/go-tarantool).


## Load Test

Тестирование проводилось по одному и тому же api сервиса для двух конфигураций репликации:
- mysql master - mysql slave
- mysql master - replicator - tarantool slave

База данных наполнена 1 млн записей пользователей, сгенерированных с помощью Handler'a /api/users/mock

Для подачи нагрузки использовался lua скрипт [wkr](/wrk/random_search.lua).

```lua
request = function()
  upperCase = "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
  wrk.headers["Connection"] = "Keep-Alive"
  rand = math.random(#upperCase)
  rand2 = math.random(#upperCase)
  path = "/api/users/search/?first_name=" .. string.sub(upperCase, rand, rand) .. "&last_name=" .. string.sub(upperCase, rand2, rand2)
  return wrk.format("GET", path)
end
```

Тип метрики | Mysql replication | Tarantool replication  
--- | --- | --- 
latency (ms), 100 connections | 1243 | 610  
throughput, 100 connections | 96,4 |  286,9

По результатам нагрузочного тестирования:
- latency у tarantool меньше примерно в 1,5-2 раза
- throughput у tarantool больше примерно в 2,5-3 раза