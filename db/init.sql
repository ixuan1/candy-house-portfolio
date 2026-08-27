-- 糖果屋 · 建库建表脚本（挂载到 MySQL 容器的 /docker-entrypoint-initdb.d/ 会自动执行）
-- 注意：按你的要求不写入任何假数据，表建好后是空的，请用管理页添加真实作品。

CREATE DATABASE IF NOT EXISTS candy_house
  DEFAULT CHARACTER SET utf8mb4
  DEFAULT COLLATE utf8mb4_unicode_ci;

USE candy_house;

CREATE TABLE IF NOT EXISTS works (
  id          INT          NOT NULL AUTO_INCREMENT,
  title       VARCHAR(120) NOT NULL                COMMENT '作品名称',
  category    VARCHAR(60)  DEFAULT 'Web'          COMMENT '分类: Web/UI/Canvas...',
  color       VARCHAR(20)  DEFAULT '#FF1493'      COMMENT '糖果色 HEX',
  description TEXT                                  COMMENT '描述',
  link        VARCHAR(255) DEFAULT ''             COMMENT '外链',
  created_at  DATETIME     DEFAULT CURRENT_TIMESTAMP,
  updated_at  DATETIME     DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  KEY idx_category (category)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='作品清单';
