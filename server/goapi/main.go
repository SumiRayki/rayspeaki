package main

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"log"
	"net/http"
	"os"
	"strconv"
	"strings"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/redis/go-redis/v9"
	"golang.org/x/crypto/bcrypt"
)

var (
	db          *pgxpool.Pool
	rdb         *redis.Client
	serverPass  string
	adminPass   string
	sessionTTL  = 24 * time.Hour * 7
)

type Session struct {
	Identity string `json:"identity"`
	Role     string `json:"role"`
	UserID   int    `json:"userId"`
}

// ---------- helpers ----------

func generateToken() string {
	b := make([]byte, 32)
	rand.Read(b)
	return hex.EncodeToString(b)
}

func getSession(r *http.Request) (*Session, string, error) {
	token := r.Header.Get("X-Session-Token")
	if token == "" {
		token = r.URL.Query().Get("session")
	}
	if token == "" {
		return nil, "", nil
	}
	val, err := rdb.Get(r.Context(), "session:"+token).Result()
	if err != nil {
		return nil, token, nil
	}
	var s Session
	if err := json.Unmarshal([]byte(val), &s); err != nil {
		return nil, token, nil
	}
	return &s, token, nil
}

func writeJSON(w http.ResponseWriter, code int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	json.NewEncoder(w).Encode(v)
}

func writeError(w http.ResponseWriter, code int, msg string) {
	writeJSON(w, code, map[string]string{"error": msg})
}

func cors(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		origin := r.Header.Get("Origin")
		if origin == "" {
			origin = "*"
		}
		w.Header().Set("Access-Control-Allow-Origin", origin)
		w.Header().Set("Access-Control-Allow-Credentials", "true")
		w.Header().Set("Access-Control-Allow-Methods", "GET,POST,PUT,DELETE,OPTIONS")
		w.Header().Set("Access-Control-Allow-Headers", "Content-Type,X-Session-Token")
		if r.Method == http.MethodOptions {
			w.WriteHeader(http.StatusNoContent)
			return
		}
		next.ServeHTTP(w, r)
	})
}

// ---------- handlers ----------

// POST /api/login
// Body: {"username":"...","password":"..."}
// Returns: {"session":"...","identity":"...","role":"..."}
func handleLogin(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeError(w, http.StatusMethodNotAllowed, "method not allowed")
		return
	}
	var body struct {
		Username string `json:"username"`
		Password string `json:"password"`
	}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil || body.Username == "" || body.Password == "" {
		writeError(w, http.StatusBadRequest, "username and password required")
		return
	}

	role := ""
	if body.Password == adminPass {
		role = "admin"
	} else if body.Password == serverPass {
		role = "user"
	} else {
		writeError(w, http.StatusUnauthorized, "invalid password")
		return
	}

	// Upsert user record
	var userID int
	err := db.QueryRow(context.Background(),
		`INSERT INTO users (username, role) VALUES ($1, $2)
		 ON CONFLICT (username) DO UPDATE SET role = $2
		 RETURNING id`,
		body.Username, role,
	).Scan(&userID)
	if err != nil {
		log.Printf("upsert user: %v", err)
		writeError(w, http.StatusInternalServerError, "database error")
		return
	}

	token := generateToken()
	sess := Session{Identity: body.Username, Role: role, UserID: userID}
	data, _ := json.Marshal(sess)
	rdb.Set(r.Context(), "session:"+token, data, sessionTTL)

	writeJSON(w, http.StatusOK, map[string]string{
		"session":  token,
		"identity": sess.Identity,
		"role":     sess.Role,
	})
}

// POST /api/logout
func handleLogout(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeError(w, http.StatusMethodNotAllowed, "method not allowed")
		return
	}
	_, token, _ := getSession(r)
	if token != "" {
		rdb.Del(r.Context(), "session:"+token)
	}
	writeJSON(w, http.StatusOK, map[string]string{"ok": "logged out"})
}

// GET /api/me
func handleMe(w http.ResponseWriter, r *http.Request) {
	sess, _, _ := getSession(r)
	if sess == nil {
		writeError(w, http.StatusUnauthorized, "not authenticated")
		return
	}
	var avatar *string
	db.QueryRow(r.Context(), `SELECT avatar FROM users WHERE username = $1`, sess.Identity).Scan(&avatar)
	av := ""
	if avatar != nil {
		av = *avatar
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"identity": sess.Identity,
		"role":     sess.Role,
		"avatar":   av,
	})
}

// GET /api/channels  →  [{id, name}]
// POST /api/channels →  body: {name:"..."}  (admin)
// DELETE /api/channels/:id  (admin)
func handleChannels(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()

	switch r.Method {
	case http.MethodGet:
		sess, _, _ := getSession(r)
		if sess == nil {
			writeError(w, http.StatusUnauthorized, "not authenticated")
			return
		}
		rows, err := db.Query(ctx, `SELECT id, name, COALESCE(background, ''), COALESCE(password, '') FROM channels ORDER BY id`)
		if err != nil {
			writeError(w, http.StatusInternalServerError, "database error")
			return
		}
		defer rows.Close()
		type Channel struct {
			ID          int    `json:"id"`
			Name        string `json:"name"`
			Background  string `json:"background"`
			HasPassword bool   `json:"hasPassword"`
		}
		channels := []Channel{}
		for rows.Next() {
			var c Channel
			var pw string
			rows.Scan(&c.ID, &c.Name, &c.Background, &pw)
			c.HasPassword = pw != ""
			channels = append(channels, c)
		}
		writeJSON(w, http.StatusOK, channels)

	case http.MethodPost:
		sess, _, _ := getSession(r)
		if sess == nil || sess.Role != "admin" {
			writeError(w, http.StatusForbidden, "admin only")
			return
		}
		var body struct {
			Name string `json:"name"`
		}
		if err := json.NewDecoder(r.Body).Decode(&body); err != nil || strings.TrimSpace(body.Name) == "" {
			writeError(w, http.StatusBadRequest, "name required")
			return
		}
		var id int
		err := db.QueryRow(ctx, `INSERT INTO channels (name) VALUES ($1) RETURNING id`, body.Name).Scan(&id)
		if err != nil {
			writeError(w, http.StatusInternalServerError, "database error")
			return
		}
		writeJSON(w, http.StatusOK, map[string]any{"id": id, "name": body.Name})

	default:
		writeError(w, http.StatusMethodNotAllowed, "method not allowed")
	}
}

// PUT /api/channels/{id}  — rename channel (admin)
// DELETE /api/channels/{id} — delete channel (admin)
func handleChannelByID(w http.ResponseWriter, r *http.Request) {
	sess, _, _ := getSession(r)
	if sess == nil || sess.Role != "admin" {
		writeError(w, http.StatusForbidden, "admin only")
		return
	}
	idStr := strings.TrimPrefix(r.URL.Path, "/api/channels/")
	id, err := strconv.Atoi(idStr)
	if err != nil {
		writeError(w, http.StatusBadRequest, "invalid id")
		return
	}

	switch r.Method {
	case http.MethodPut:
		var body struct {
			Name       *string `json:"name"`
			Background *string `json:"background"`
			Password   *string `json:"password"`
		}
		if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
			writeError(w, http.StatusBadRequest, "invalid body")
			return
		}
		if body.Name != nil && strings.TrimSpace(*body.Name) != "" {
			_, err := db.Exec(r.Context(), `UPDATE channels SET name = $1 WHERE id = $2`, strings.TrimSpace(*body.Name), id)
			if err != nil {
				writeError(w, http.StatusInternalServerError, "database error")
				return
			}
		}
		if body.Background != nil {
			// Limit background data to ~1MB
			if len(*body.Background) > 1024*1024 {
				writeError(w, http.StatusBadRequest, "background too large")
				return
			}
			_, err := db.Exec(r.Context(), `UPDATE channels SET background = $1 WHERE id = $2`, *body.Background, id)
			if err != nil {
				writeError(w, http.StatusInternalServerError, "database error")
				return
			}
		}
		if body.Password != nil {
			_, err := db.Exec(r.Context(), `UPDATE channels SET password = $1 WHERE id = $2`, *body.Password, id)
			if err != nil {
				writeError(w, http.StatusInternalServerError, "database error")
				return
			}
		}
		if body.Name == nil && body.Background == nil && body.Password == nil {
			writeError(w, http.StatusBadRequest, "name, background or password required")
			return
		}
		writeJSON(w, http.StatusOK, map[string]string{"ok": "updated"})

	case http.MethodDelete:
		_, err = db.Exec(r.Context(), `DELETE FROM channels WHERE id = $1`, id)
		if err != nil {
			writeError(w, http.StatusInternalServerError, "database error")
			return
		}
		writeJSON(w, http.StatusOK, map[string]string{"ok": "deleted"})

	default:
		writeError(w, http.StatusMethodNotAllowed, "method not allowed")
	}
}

// PUT /api/avatar — upload avatar (base64 data URL, max ~256KB)
func handleAvatar(w http.ResponseWriter, r *http.Request) {
	if r.Method == http.MethodGet {
		// GET /api/avatar?username=...
		username := r.URL.Query().Get("username")
		if username == "" {
			writeError(w, http.StatusBadRequest, "username required")
			return
		}
		var avatar *string
		err := db.QueryRow(r.Context(), `SELECT avatar FROM users WHERE username = $1`, username).Scan(&avatar)
		if err != nil || avatar == nil {
			writeJSON(w, http.StatusOK, map[string]string{"avatar": ""})
			return
		}
		writeJSON(w, http.StatusOK, map[string]string{"avatar": *avatar})
		return
	}
	if r.Method != http.MethodPut {
		writeError(w, http.StatusMethodNotAllowed, "method not allowed")
		return
	}
	sess, _, _ := getSession(r)
	if sess == nil {
		writeError(w, http.StatusUnauthorized, "not authenticated")
		return
	}
	var body struct {
		Avatar string `json:"avatar"`
	}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		writeError(w, http.StatusBadRequest, "invalid body")
		return
	}
	// Limit to ~350KB base64 string
	if len(body.Avatar) > 350*1024 {
		writeError(w, http.StatusBadRequest, "avatar too large (max 256KB)")
		return
	}
	_, err := db.Exec(r.Context(), `UPDATE users SET avatar = $1 WHERE username = $2`, body.Avatar, sess.Identity)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "database error")
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"ok": "avatar updated"})
}

// GET /api/downloads — list download links
// PUT /api/downloads — update download links (admin)
func handleDownloads(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	switch r.Method {
	case http.MethodGet:
		sess, _, _ := getSession(r)
		if sess == nil {
			writeError(w, http.StatusUnauthorized, "not authenticated")
			return
		}
		rows, err := db.Query(ctx, `SELECT platform, url FROM downloads ORDER BY platform`)
		if err != nil {
			writeError(w, http.StatusInternalServerError, "database error")
			return
		}
		defer rows.Close()
		links := map[string]string{}
		for rows.Next() {
			var platform, url string
			rows.Scan(&platform, &url)
			links[platform] = url
		}
		writeJSON(w, http.StatusOK, links)

	case http.MethodPut:
		sess, _, _ := getSession(r)
		if sess == nil || sess.Role != "admin" {
			writeError(w, http.StatusForbidden, "admin only")
			return
		}
		var body map[string]string
		if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
			writeError(w, http.StatusBadRequest, "invalid body")
			return
		}
		for platform, url := range body {
			platform = strings.TrimSpace(platform)
			url = strings.TrimSpace(url)
			if platform == "" {
				continue
			}
			if url == "" {
				db.Exec(ctx, `DELETE FROM downloads WHERE platform = $1`, platform)
			} else {
				db.Exec(ctx, `INSERT INTO downloads (platform, url) VALUES ($1, $2) ON CONFLICT (platform) DO UPDATE SET url = $2`, platform, url)
			}
		}
		writeJSON(w, http.StatusOK, map[string]string{"ok": "updated"})

	default:
		writeError(w, http.StatusMethodNotAllowed, "method not allowed")
	}
}

// ---------- schema migration ----------

func migrate(ctx context.Context) error {
	_, err := db.Exec(ctx, `
		CREATE TABLE IF NOT EXISTS users (
			id         SERIAL PRIMARY KEY,
			username   VARCHAR(100) UNIQUE NOT NULL,
			role       VARCHAR(20)  NOT NULL DEFAULT 'user',
			created_at TIMESTAMPTZ  NOT NULL DEFAULT NOW()
		);
		CREATE TABLE IF NOT EXISTS channels (
			id         SERIAL PRIMARY KEY,
			name       VARCHAR(100) NOT NULL,
			created_at TIMESTAMPTZ  NOT NULL DEFAULT NOW()
		);
		INSERT INTO channels (name) VALUES ('General'), ('Gaming'), ('AFK')
		ON CONFLICT DO NOTHING;
	`)
	if err != nil {
		return err
	}
	// Add avatar column if not exists
	_, _ = db.Exec(ctx, `ALTER TABLE users ADD COLUMN IF NOT EXISTS avatar TEXT`)
	// Add background column to channels
	_, _ = db.Exec(ctx, `ALTER TABLE channels ADD COLUMN IF NOT EXISTS background TEXT`)
	// Add password column to channels
	_, _ = db.Exec(ctx, `ALTER TABLE channels ADD COLUMN IF NOT EXISTS password TEXT NOT NULL DEFAULT ''`)
	// Add downloads table
	_, err = db.Exec(ctx, `CREATE TABLE IF NOT EXISTS downloads (platform VARCHAR(50) PRIMARY KEY, url TEXT NOT NULL)`)
	return err
}

// ---------- main ----------

func main() {
	serverPass = os.Getenv("SERVER_PASSWORD")
	adminPass = os.Getenv("ADMIN_PASSWORD")
	if serverPass == "" {
		serverPass = "changeme"
	}
	if adminPass == "" {
		adminPass = "admin_changeme"
	}

	port := os.Getenv("API_PORT")
	if port == "" {
		port = "3000"
	}

	dbURL := os.Getenv("DB_URL")
	if dbURL == "" {
		dbURL = "postgres://rayspeaki:rayspeaki@127.0.0.1:5432/rayspeaki"
	}
	redisURL := os.Getenv("REDIS_URL")
	if redisURL == "" {
		redisURL = "redis://127.0.0.1:6379"
	}

	// Connect with retry
	var err error
	for i := 0; i < 10; i++ {
		db, err = pgxpool.New(context.Background(), dbURL)
		if err == nil {
			if pingErr := db.Ping(context.Background()); pingErr == nil {
				break
			}
		}
		log.Printf("waiting for postgres... (%d/10)", i+1)
		time.Sleep(3 * time.Second)
	}
	if err != nil {
		log.Fatalf("connect postgres: %v", err)
	}
	if err := migrate(context.Background()); err != nil {
		log.Fatalf("migrate: %v", err)
	}
	log.Println("postgres connected")

	opt, _ := redis.ParseURL(redisURL)
	rdb = redis.NewClient(opt)
	for i := 0; i < 10; i++ {
		if rdb.Ping(context.Background()).Err() == nil {
			break
		}
		log.Printf("waiting for redis... (%d/10)", i+1)
		time.Sleep(2 * time.Second)
	}
	log.Println("redis connected")

	_ = bcrypt.CompareHashAndPassword // imported for future use

	mux := http.NewServeMux()
	mux.HandleFunc("/api/login", handleLogin)
	mux.HandleFunc("/api/logout", handleLogout)
	mux.HandleFunc("/api/me", handleMe)
	mux.HandleFunc("/api/avatar", handleAvatar)
	mux.HandleFunc("/api/channels", handleChannels)
	mux.HandleFunc("/api/channels/", handleChannelByID)
	mux.HandleFunc("/api/downloads", handleDownloads)
	mux.HandleFunc("/health", func(w http.ResponseWriter, r *http.Request) {
		w.Write([]byte("ok"))
	})

	handler := cors(mux)
	log.Printf("Go API listening on :%s", port)
	if err := http.ListenAndServe(":"+port, handler); err != nil {
		log.Fatalf("server: %v", err)
	}
}
