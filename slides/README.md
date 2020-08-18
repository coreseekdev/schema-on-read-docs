# Log Benchmark


## 变更记录


### 05/06 变更

- 优化 Schema on Read (代码内部也称之为 Runtime Schema， 下面同)， 对于同一个数据提取表达式（要求 提取组，过滤器，缺省值 均一致），结果进行了缓存
- 优化 Schema on Read ， 调整为只读取一次 Doc Store, 

> tar 解压 gz 压缩的日志文件的时间 = 2.789s

```
real    0m2.789s
user    0m2.633s
sys 0m0.959s
```

> 进行查询的时间 select id, abc('mtype', 'ipv4', 'hello') as k, abc('mtype', 'ipv4', 'hello') as y, abc() as c from csv where c > 0 option schema=abc('body:org\\.apache\\.hadoop\\.(?P<mtype>[\\w\\.]+)') FACET abc('mtype', 'ipv4', 'hello') as g;

```
|   22 | hdfs.server.datanode.web.DatanodeHttpServer         | hdfs.server.datanode.web.DatanodeHttpServer         |    2 |
|   23 | hdfs.server.datanode.DataNode                       | hdfs.server.datanode.DataNode                       |    2 |
+------+-----------------------------------------------------+-----------------------------------------------------+------+
20 rows in set (6.15 sec)
```

对比之前的版本，缩减了接近一半，考虑到这个测试查询覆盖的文档数量 (~2611376) vs. 2611376 , 需要从压缩文档中读取全部的日志信息 + 正则表达式匹配， 运行时间的下限可能在 3s 左右。

对于覆盖 1/2 以上文档的查询请求，其执行时间接近上述全部扫描的结果。

对于少数特殊日志， 例如

> select id, abc('mtype', 'ipv4', 'hello') as k, abc('mtype', 'ipv4', 'hello') as y, abc() as c from csv where MATCH('org apache hadoop metrics2') AND c > 0 option schema=abc('body:org\\.apache\\.hadoop\\.(?P<mtype>[\\w\\.]+)') FACET abc('mtype', 'ipv4', 'hello') as g;

进行数据读取与解析的时间与仅进行全文检索近似。


### 05/06 存在的问题

- DocStore 依旧潜在的存在一个数据区块多次解压，缓存失效的问题




## 使用

本系统用于对比测试 Lucene 与 定制版本的 ManticoreSearch 的性能， Working in Progress.

- 本程序必须在 Python 3.8 环境下运行（因为使用了 multiprocessing.shared_memory 特性，用于性能寄存器）

- 需要额外安装依赖的 第三方 python 包

    > pip install -r requirements.txt

- 本程序假设的测试 数据来自 https://github.com/logpai/loghub， 目前支持其中的 HDFS_2 日志格式

    1. 这个格式已 时间戳 为分割，支持 单行 和 多行 日志
    2. 其他的格式可能需要开发插件


- 进行索引前，需要先转换数据到 csv 格式，也可 在 控制台上 使用管道进行

    > python main_cli.py source -t hdfs ../LogHubData/HDFS_2/*.log 


    目前的代码中，转换完一个文件后就退出，需要调整相关脚本
    
- 索引会默认构建在当前目录的

    > ../logengine 

    目录中，为当前目录的兄弟目录。

    注意： 需要确保此目录为空！！！ 需要确保此目录为空！！！ 需要确保此目录为空！！！

- Lucene 端的测试，目前仅索引建立
    
    > python tst_lucene_build.py ../benchmark csv

    在文件 tst_lucene_build.py 中，定义了 任务 csv 所需要的格式

- Manticore 端的测试，目前仅索引建立

    > indexer  -c template/manticore.conf.in csv

    在 文件 template/manticore.conf.in 给出了索引 csv 的定义

    具体使用，请参看 https://docs.manticoresearch.com/latest/html/index.html


## 索引结构

与 Splunk 相同， 日志索引格式为

    (id, stream_id, create_time, body)

其他事项

- Lucene 与 Manticore 的索引结构均如上，其中 stream_id 为 文件名的 cityhash64    
- 均存储了日志正文
- 均未保存 Hit 的 position 信息 （Lucene 版本存疑）

> Splunk 中 level-1 index，还额外提供 index_time， 此处未提供;

## 对 Manticore 的构建说明

    - 在 CentOS 7 上可运行的 二进制在 bin 子目录中 

    - 因为 CentOS 7 的构建环境存在部分有待解决的问题，以下特性被禁用

        + ICU
        + RE2
        + GALERA
        + GTest
    
    - 未启用中文分词（对日志检索并不重要）

    - 启用了索引压缩与文档压缩

        > 因时间原因， 未启用 RT Index 的索引压缩支持。如需要测试，可增加

    - 需要使用 MySQL 协议访问 searchd， 需要使用 mysql client 的命令行。 暂时无法使用 MySQL WorkBench 连接

      >  mysql -P 9306 -h 127.0.0.1  

    - Schema on Read

## Schema on Read 的说明

Schema on Read 用于处理在构建索引时，最终用户对日志的数据项目构成还不了解时， 根据 正则表达式 动态创建 检索的 Schema 进行检索和分析，无需重建索引。

本功能依赖正则表达式引擎，需要安装 libpcre 。

具体语法为：

> select abc('g1', 'ipv4', 'ccc') as ip from csv where id<10 option schema=abc('body:(abc)')

需要使用扩展的 `option schema=$result_namespace(field_name:$regex_expr)` 表达方式， 其中

    - result_namespace 为此表达式对应结果的名字，可以在 select 子句中进行引用
    - field_name 为需要进行抽取的全文检索字段或字符串属性，如果是全文检索字段，需要配置 stored_fields
    - regex_expr 为进行数据抽取的正则表达式， 需要至少包括一个 catpure group, 可以在 select 子句中，使用名字或数字编号进行引用

扩展的 option schema 设置可以有多个， 使用不同的 result_namespace 进行区分

    > 注意： 系统的当前版本中，没有对 result_namespace 相同的情况进行检测，使用相同的 result_namespace 可能导致系统崩溃或其他未知反应。

抽取出的结果可以进行 group by

    > select abc('g1', 'ipv4', 'ccc') as ip, count(*) from csv where id<10 group by ip option schema=abc('body:(abc)');

对于同时需要进行多方面 分面统计的情况， 还可以通过 扩展的 FACET 语法进行检索, 这个 FACET 可以出现多次

    > select abc('g1', 'ipv4', 'ccc') as ip from csv where id<10 option schema=abc('body:(abc)') FACET abc('g1', 'ipv4', 'aaa') as p;

需要注意的一点是，在 FACET 子句中， 目前暂时不能使用 select 子句中 alias 出的计算字段，而只能重新将表达式 写一遍， 这会轻微的降低性能。

在 select 子句中，表达字段的语法为 `$result_namespace($capture, $filter, $default_value) as $field_name` , 其中

    - $result_namespace 为 在 option schema 子句中给出的 名字
    - $capture 为 正则表达式 捕获的 captrue group 序号 或 名字

        > capture 可以是一个列表并用 ',' 分隔， 目前的实现中，只处理第一个 capture ，需要对 filter 的支持启用用，方可支持多个 capture.

    - $filter 为内置的过滤器， 可以为 空

        > 目前的版本，无论 filter 给何值，均不进行任何额外作业。此处典型的应用是， 进行 ip 地址转换，进行时间日期转换

    - $default_value 为匹配失败时, 当前表达式默认返回的值。这个值的类型可以是 字符串、浮点数、整型, 可以 不提供

        > 当  capture group 捕获的子字符串可以进行转化时，会自动转化成  $default_value 对应的类型
        > 当  $default_value 不给出时，即 `$result_namespace($capture, $filter, $default_value)` 或 `$result_namespace($capture)` , 返回类型 为 string ，未匹配 返回为 Null

    当 仅提供了两个参数时， 系统视为 `$result_namespace($capture, $default_value) as $field_name`

    - 未提供， 一个潜在的典型实现是在 match 子句（具体参考 manticore 文档）中出现正则表达式出现的关键词， 在 where 条件中，用 regex 函数 要求 文档必须命中这个正则表达式，用于提高运行效率。

        - 当前版本中，不支持函数 regex

### 调试功能

    通过传入预制的命令 ID ，可以启用 `$result_namespace($capture, $filter, $default_value) as $field_name` 的调试功能。

    目前支持的命令 ID 有

        0           返回正则表达式执行的状态码，对于成功执行，是命中的 group 数。
       -1           返回执行的结果 或 错误信息  


### 限制

    - 单一的 local index ，文档数量不能超过 2**32 - 1 , 因为系统内部使用 32bit 编码文档正文ID
    - 单一的 正则表达式 包括的匹配组 不能超过 [512/3] ~ 170 

    - 因为 SQL 解析器的关系，正则表达式中出现的 \ 需要进行转义， 调整为 \\
    - 因为 SQL 解析器的关系，正则表达式中出现的 \ 需要进行转义， 调整为 \\
    - 因为 SQL 解析器的关系，正则表达式中出现的 \ 需要进行转义， 调整为 \\


### 可能的扩展

    系统保留了接入 LuaJIT 的接口， 可以扩展为 允许用户下发 Lua 脚本，进行属性抽取


### 测试示例
    
    调试： 显示正则表达式的执行结果

    > select id, abc(-1) as c from csv where id >1 and id<5 option schema=abc('body:org\\.apache\\.hadoop\\.metrics2\\.impl\\.(\\w*)');

    调试： 正则表达式的执行状态码， 需要注意 如果是 带 参数 0 ， 返回的类型为字符串， 如果不带参数， 返回的类型为 int64.

    > select id, abc(0) as c from csv where id >1 and id<5 option schema=abc('body:org\\.apache\\.hadoop\\.metrics2\\.impl\\.(\\w*)');

    > select id, abc() as c from csv where id >1 and id<5 option schema=abc('body:org\\.apache\\.hadoop\\.metrics2\\.impl\\.(\\w*)');

    抽取 具体的 metrics 类型，并进行分面统计

    > select id, abc('mtype', 'ipv4', '_') as c from csv option schema=abc('body:org\\.apache\\.hadoop\\.metrics2\\.(?P<mtype>\\w*)');

    使用 全文检索的能力，对文档进行提前过滤; 使用 order by 覆盖掉搜索引擎的 rank 机制

    > select id, abc('mtype', 'ipv4', '_') as c from csv WHERE MATCH('org apache hadoop metrics2') ORDER BY id option schema=abc('body:org\\.apache\\.hadoop\\.metrics2\\.(?P<mtype>\\w*)');

    > select id, abc('mtype', 'ipv4', 'hello') as k from csv option schema=abc('body:org\\.apache\\.hadoop\\.(?P<mtype>[\\w\\.]+)') FACET abc('mtype', 'ipv4', 'hello') as g;

### 存在的问题
	
	1. 因为正文被压缩存储在磁盘， 访问的时候需要解压缩 导致处理时间就较长。 模拟测试中， 如果跳过文档解压的步骤，查询时间由 9.5s 缩短到 1.1s 


## Micro Benchmark Result

>  time ../centos_manticore/src/indexer  -c template/manticore.conf.in csv

real	0m52.984s
user	0m51.581s
sys	0m1.719s

>  time /usr/bin/java -server -Xms2g -Xmx2g -XX:-TieredCompilation -XX:+HeapDumpOnOutOfMemoryError -Xbatch -classpath "....

注意， 因为 Python 命令有编译的步骤，因此实际测试需要调整脚本 或 使用 脚本输出的命令。

real	1m6.025s
user	1m22.628s
sys	0m7.917s

Index Size：

173M vs. 208M

## 存在的问题

1. 我不是 Java 专家， 代码主要修改自 Lucenen nightly 的 benchmark ， 是否还额外存在性能优化手段未知
2. 启用 position index 后，索引大小会急剧膨胀。需要进一步的额外工作


（以下非正文）

-----------------------------

用于测试日志管理系统的性能测试工具。 

1. 对比了 Lucene (制作本工具时最新版为 8.5.1) 与 其他检索系统 （eg. MantiCoreSearch ) 的

    - 建立索引的性能
    - 查询性能
    - 磁盘文件占用
    - TBD： 内存占用 与 IO 情况
    
    > Lucene 部分的构建逻辑 部分来自 https://github.com/mikemccand/luceneutil
 
2. TBD： 针对日志采集工具

    - 数据吞吐量
    

## 安装

1. 注意， 本程序必须在 Python 3.8 环境下运行（因为使用了 multiprocessing.shared_memory 特性）

## TODO

### Luceneutil
 
- [X] 从源代码构建 Lucene
- [X] 适配 Java 用于构建索引的代码

### LogHub