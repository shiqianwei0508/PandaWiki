package pg

import (
	"database/sql"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"strconv"
	"time"

	"github.com/golang-migrate/migrate/v4"
	migratePG "github.com/golang-migrate/migrate/v4/database/postgres"
	_ "github.com/golang-migrate/migrate/v4/source/file"
	"gorm.io/driver/postgres"
	"gorm.io/gorm"
	"gorm.io/gorm/logger"

	"github.com/chaitin/panda-wiki/config"
)

type DB struct {
	*gorm.DB
}

func NewDB(config *config.Config) (*DB, error) {
	dsn := config.PG.DSN
	// same as gorm logger.Default, but without colorful output and ignore record not found error
	newLogger := logger.New(log.New(os.Stdout, "\r\n", log.LstdFlags), logger.Config{
		SlowThreshold:             200 * time.Millisecond,
		LogLevel:                  logger.Warn,
		IgnoreRecordNotFoundError: true,
		Colorful:                  false,
	})
	db, err := gorm.Open(postgres.Open(dsn), &gorm.Config{
		TranslateError: true,
		Logger:         newLogger,
	})
	if err != nil {
		return nil, err
	}
	// create raglite database if not exists
	var exists bool
	if err := db.Raw("SELECT EXISTS(SELECT 1 FROM pg_database WHERE datname = 'raglite')").Scan(&exists).Error; err != nil {
		return nil, err
	}
	if !exists {
		if err := db.Exec("CREATE DATABASE raglite").Error; err != nil {
			return nil, err
		}
	}
	if err := doMigrate(dsn); err != nil {
		return nil, err
	}

	return &DB{DB: db}, nil
}

func doMigrate(dsn string) error {
	migrationFiles, err := filepath.Glob("migration/*.up.sql")
	if err != nil {
		return fmt.Errorf("scan migration files failed: %w", err)
	}
	// 支持仅保留完整部署 SQL 的交付方式：无增量迁移文件时跳过自动迁移。
	if len(migrationFiles) == 0 {
		return nil
	}

	// 磁盘上最高的增量版本号（如 000038_xxx.up.sql -> 38）。
	diskMaxVersion := 0
	for _, f := range migrationFiles {
		v, ok := parseMigrationVersion(f)
		if !ok {
			continue
		}
		if v > diskMaxVersion {
			diskMaxVersion = v
		}
	}

	db, err := sql.Open("postgres", dsn)
	if err != nil {
		return fmt.Errorf("open db failed: %w", err)
	}
	defer db.Close()

	// 查询数据库当前已应用的迁移版本。
	// 全新库（schema_migrations 表不存在或为空）视为 0。
	dbCurrentVersion := queryCurrentMigrationVersion(db)

	// 若数据库版本已领先于磁盘增量文件的最高版本，说明该库已通过
	// full_fresh_deploy.sql 全量部署到位（版本号高于增量文件覆盖范围）。
	// 此时直接跳过 golang-migrate，避免其尝试读取不存在的高版本 down 文件而 panic。
	if dbCurrentVersion > diskMaxVersion {
		return nil
	}

	driver, err := migratePG.WithInstance(db, &migratePG.Config{})
	if err != nil {
		return fmt.Errorf("with instance failed: %w", err)
	}
	m, err := migrate.NewWithDatabaseInstance(
		"file://migration",
		"postgres", driver)
	if err != nil {
		return fmt.Errorf("new with database instance failed: %w", err)
	}
	if err := m.Up(); err != nil {
		if err == migrate.ErrNoChange {
			return nil
		}
		return fmt.Errorf("migrate db failed: %w", err)
	}

	return nil
}

// parseMigrationVersion 从迁移文件名中解析版本号。
// 文件名形如 000038_create_node_release_backups.up.sql，返回 38。
func parseMigrationVersion(filename string) (int, bool) {
	base := filepath.Base(filename)
	if len(base) < 6 {
		return 0, false
	}
	prefix := base[:6]
	if !isAllDigits(prefix) {
		return 0, false
	}
	v, err := strconv.Atoi(prefix)
	if err != nil {
		return 0, false
	}
	return v, true
}

func isAllDigits(s string) bool {
	for _, c := range s {
		if c < '0' || c > '9' {
			return false
		}
	}
	return true
}

// queryCurrentMigrationVersion 读取 schema_migrations 表中已应用的最高版本。
// 表不存在或查询失败时返回 0（视为全新库）。
func queryCurrentMigrationVersion(db *sql.DB) int {
	var version int
	err := db.QueryRow(
		"SELECT version FROM schema_migrations ORDER BY version DESC LIMIT 1",
	).Scan(&version)
	if err != nil {
		return 0
	}
	return version
}
