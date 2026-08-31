use std::str::FromStr;

use anyhow::{bail, Result};
use clap::{ArgGroup, Parser};
use sqlx::{sqlite::SqliteConnectOptions, SqlitePool};

#[derive(Parser)]
#[command(
    name = "bootstrap-admin",
    about = "Promote the first administrator in an existing database",
    group(ArgGroup::new("selector").required(true).args(["user_id", "discord_id"]))
)]
struct Cli {
    #[arg(long)]
    database_url: String,

    #[arg(long)]
    user_id: Option<i64>,

    #[arg(long)]
    discord_id: Option<String>,
}

enum Selector {
    UserId(i64),
    DiscordId(String),
}

impl Cli {
    fn selector(self) -> Selector {
        match (self.user_id, self.discord_id) {
            (Some(user_id), None) => Selector::UserId(user_id),
            (None, Some(discord_id)) => Selector::DiscordId(discord_id),
            _ => unreachable!("clap requires exactly one selector"),
        }
    }
}

#[tokio::main]
async fn main() -> Result<()> {
    let cli = Cli::parse();
    let options = SqliteConnectOptions::from_str(&cli.database_url)?.create_if_missing(false);
    let pool = SqlitePool::connect_with(options).await?;
    let id = bootstrap(&pool, cli.selector()).await?;
    println!("Promoted user {id} to ADMIN.");
    Ok(())
}

async fn bootstrap(pool: &SqlitePool, selector: Selector) -> Result<i64> {
    let mut connection = pool.acquire().await?;
    sqlx::query("BEGIN IMMEDIATE")
        .execute(&mut *connection)
        .await?;

    let result = async {
        let admin_count: i64 =
            sqlx::query_scalar("SELECT COUNT(*) FROM users WHERE auth = 'ADMIN'")
                .fetch_one(&mut *connection)
                .await?;
        if admin_count != 0 {
            bail!("an administrator already exists");
        }

        let user_ids: Vec<i64> = match selector {
            Selector::UserId(user_id) => {
                sqlx::query_scalar("SELECT id FROM users WHERE id = ?")
                    .bind(user_id)
                    .fetch_all(&mut *connection)
                    .await?
            }
            Selector::DiscordId(discord_id) => {
                sqlx::query_scalar("SELECT id FROM users WHERE discord_id = ?")
                    .bind(discord_id)
                    .fetch_all(&mut *connection)
                    .await?
            }
        };

        let [user_id] = user_ids.as_slice() else {
            bail!("selector must match exactly one existing user");
        };
        sqlx::query("UPDATE users SET auth = 'ADMIN' WHERE id = ?")
            .bind(user_id)
            .execute(&mut *connection)
            .await?;
        Ok(*user_id)
    }
    .await;

    match result {
        Ok(user_id) => {
            sqlx::query("COMMIT").execute(&mut *connection).await?;
            Ok(user_id)
        }
        Err(error) => {
            let _ = sqlx::query("ROLLBACK").execute(&mut *connection).await;
            Err(error)
        }
    }
}

#[cfg(test)]
mod tests {
    use clap::Parser;
    use sqlx::{sqlite::SqlitePoolOptions, SqlitePool};

    use super::{bootstrap, Cli, Selector};

    async fn database() -> SqlitePool {
        let pool = SqlitePoolOptions::new()
            .max_connections(1)
            .connect("sqlite::memory:")
            .await
            .unwrap();
        sqlx::query(
            "CREATE TABLE users (
                id INTEGER PRIMARY KEY NOT NULL,
                auth TEXT NOT NULL DEFAULT 'MEMBER',
                name TEXT NOT NULL,
                username TEXT UNIQUE COLLATE NOCASE NOT NULL,
                discord_id TEXT NOT NULL,
                note TEXT NOT NULL DEFAULT 'unchanged'
            )",
        )
        .execute(&pool)
        .await
        .unwrap();
        pool
    }

    async fn user(pool: &SqlitePool, id: i64, discord_id: &str) {
        sqlx::query("INSERT INTO users (id, name, username, discord_id) VALUES (?, 'Name', ?, ?)")
            .bind(id)
            .bind(format!("user{id}"))
            .bind(discord_id)
            .execute(pool)
            .await
            .unwrap();
    }

    #[test]
    fn selector_requires_exactly_one_value() {
        assert!(
            Cli::try_parse_from(["bootstrap-admin", "--database-url", "sqlite::memory:"]).is_err()
        );
        assert!(Cli::try_parse_from([
            "bootstrap-admin",
            "--database-url",
            "sqlite::memory:",
            "--user-id",
            "1",
            "--discord-id",
            "discord",
        ])
        .is_err());
        assert!(Cli::try_parse_from([
            "bootstrap-admin",
            "--database-url",
            "sqlite::memory:",
            "--user-id",
            "1",
        ])
        .is_ok());
    }

    #[tokio::test]
    async fn rejects_a_missing_user() {
        let pool = database().await;

        assert!(bootstrap(&pool, Selector::UserId(99)).await.is_err());
    }

    #[tokio::test]
    async fn promotes_the_selected_user() {
        let pool = database().await;
        user(&pool, 7, "discord-7").await;

        assert_eq!(bootstrap(&pool, Selector::UserId(7)).await.unwrap(), 7);
        let auth: String = sqlx::query_scalar("SELECT auth FROM users WHERE id = 7")
            .fetch_one(&pool)
            .await
            .unwrap();
        assert_eq!(auth, "ADMIN");
    }

    #[tokio::test]
    async fn rejects_duplicate_discord_ids() {
        let pool = database().await;
        user(&pool, 1, "duplicate").await;
        user(&pool, 2, "duplicate").await;

        assert!(bootstrap(&pool, Selector::DiscordId("duplicate".into()))
            .await
            .is_err());
    }

    #[tokio::test]
    async fn refuses_when_an_admin_already_exists() {
        let pool = database().await;
        user(&pool, 1, "first").await;
        user(&pool, 2, "second").await;
        sqlx::query("UPDATE users SET auth = 'ADMIN' WHERE id = 1")
            .execute(&pool)
            .await
            .unwrap();

        assert!(bootstrap(&pool, Selector::UserId(2)).await.is_err());
        let auth: String = sqlx::query_scalar("SELECT auth FROM users WHERE id = 2")
            .fetch_one(&pool)
            .await
            .unwrap();
        assert_eq!(auth, "MEMBER");
    }

    #[tokio::test]
    async fn leaves_unrelated_fields_untouched() {
        let pool = database().await;
        user(&pool, 1, "selected").await;
        user(&pool, 2, "other").await;
        sqlx::query("UPDATE users SET note = 'preserve me' WHERE id = 1")
            .execute(&pool)
            .await
            .unwrap();

        bootstrap(&pool, Selector::DiscordId("selected".into()))
            .await
            .unwrap();
        let selected: (String, String) =
            sqlx::query_as("SELECT auth, note FROM users WHERE id = 1")
                .fetch_one(&pool)
                .await
                .unwrap();
        let other: String = sqlx::query_scalar("SELECT auth FROM users WHERE id = 2")
            .fetch_one(&pool)
            .await
            .unwrap();
        assert_eq!(selected, ("ADMIN".into(), "preserve me".into()));
        assert_eq!(other, "MEMBER");
    }
}
