# Required libraries
library(shiny)
library(websocket)
library(httr2)
library(DBI)
library(RSQLite)
library(jsonlite)
library(lubridate)

db_path <- "webhook.sqlite"
if (!file.exists(db_path)) {
  con <- dbConnect(RSQLite::SQLite(), db_path)
  dbExecute(con, "CREATE TABLE webhook (id INTEGER PRIMARY KEY, url TEXT)")
  dbDisconnect(con)
}

ui <- navbarPage(
  "Alpha-Strike Mailing Socket",
  tabPanel(
    "Settings",
    fluidPage(
      div(
        style = "text-align:center;",
        div(style = "display:inline-block; margin-right:10px;", textInput("webhook", strong("Your Discord Webhook URL"), value = "")),
        div(style = "display:inline-block; margin-right:10px;", actionButton("save_webhook", "Save / Update Webhook")),
        div(style = "display:inline-block; margin-right:10px;", actionButton("delete_webhook", "Delete Webhook")),
        div(style = "display:inline-block;", actionButton("send_discord_test", "Send Test Payload to Discord"))
      ),
      br(),
      verbatimTextOutput("webhook_status")
    )
  ),
  tabPanel(
    "Debugging Stream",
    fluidPage(
      div(style = "text-align:center;",
          div(style = "display:inline-block; margin-right:10px;", strong("Socket Messaging Stream"))
      ),
      br(),
      verbatimTextOutput("ws_messages")
    )
  )
)

# Helper to convert LDAP timestamp (100-nanosecond intervals since 1601-01-01 UTC) to UTC string
ldap_to_utc <- function(ldap_timestamp) {
  if (is.null(ldap_timestamp) || is.na(ldap_timestamp)) return(NA)
  origin <- as.POSIXct("1601-01-01 00:00:00", tz = "UTC")
  seconds <- as.numeric(ldap_timestamp) / 1e7
  utc_time <- origin + seconds
  format(utc_time, "%Y-%m-%d %H:%M:%S UTC")
}

# Helper: Build a pretty Discord message from JSON
build_pretty_msg <- function(msg) {
  tryCatch({
    obj <- jsonlite::fromJSON(msg, simplifyDataFrame = TRUE)
    if (!is.null(obj$message)) {
      # Just print the message field for simple info/error messages
      return(obj$message)
    } else if (is.list(obj) && !is.null(obj$victim_name)) {
      time_str <- if (!is.null(obj$time_stamp)) ldap_to_utc(obj$time_stamp) else "Unknown time"
      return(sprintf(
        "🚨 **%s** lost a **%s** in **%s** to **%s**!\nTime: `%s`",
        obj$victim_name, obj$loss_type, obj$solar_system_name, obj$killer_name, time_str
      ))
    } else if (is.list(obj) && length(obj) > 0 && !is.null(obj[[1]]$victim_name)) {
      return(paste(
        sapply(obj, function(x) {
          time_str <- if (!is.null(x$time_stamp)) ldap_to_utc(x$time_stamp) else "Unknown time"
          sprintf(
            "🚨 **%s** lost a **%s** in **%s** to **%s**!\nTime: `%s`",
            x$victim_name, x$loss_type, x$solar_system_name, x$killer_name, time_str
          )
        }),
        collapse = "\n\n"
      ))
    } else {
      return(substr(msg, 1, 1900))
    }
  }, error = function(e) substr(msg, 1, 1900))
}

server <- function(input, output, session) {
  status_msg <- reactiveVal("No webhook set.")

  # SQLite helpers
  get_webhook <- function() {
    con <- dbConnect(RSQLite::SQLite(), db_path)
    res <- dbGetQuery(con, "SELECT url FROM webhook WHERE id = 1")
    dbDisconnect(con)
    if (nrow(res) == 1) res$url else NULL
  }
  set_webhook <- function(webhook) {
    con <- dbConnect(RSQLite::SQLite(), db_path)
    if (nchar(webhook) == 0) {
      dbExecute(con, "DELETE FROM webhook WHERE id = 1")
    } else if (is.null(get_webhook())) {
      dbExecute(con, "INSERT INTO webhook (id, url) VALUES (1, ?)", params = list(webhook))
    } else {
      dbExecute(con, "UPDATE webhook SET url = ? WHERE id = 1", params = list(webhook))
    }
    dbDisconnect(con)
  }
  delete_webhook <- function() {
    con <- dbConnect(RSQLite::SQLite(), db_path)
    dbExecute(con, "DELETE FROM webhook WHERE id = 1")
    dbDisconnect(con)
  }

  observeEvent(input$save_webhook, {
    if (nzchar(input$webhook) && grepl("^https://discord.com/api/webhooks/", input$webhook)) {
      set_webhook(input$webhook)
      status_msg("Webhook saved or updated!")
      updateTextInput(session, "webhook", value = input$webhook)
    } else {
      status_msg("Invalid Discord webhook URL.")
    }
  })

  observeEvent(input$delete_webhook, {
    delete_webhook()
    updateTextInput(session, "webhook", value = "")
    status_msg("Webhook deleted.")
  })

  observe({
    current <- get_webhook()
    if (!is.null(current)) {
      updateTextInput(session, "webhook", value = current)
      isolate({
        if (status_msg() %in% c("No webhook set.")) {
          status_msg(paste("Current webhook:", current))
        }
      })
    } else {
      updateTextInput(session, "webhook", value = "")
      isolate({
        if (status_msg() %in% c("Webhook saved or updated!", "Webhook deleted.", "Invalid Discord webhook URL.")) {
          # Do not overwrite the result message
        } else {
          status_msg("No webhook set.")
        }
      })
    }
  })

  output$webhook_status <- renderText({ status_msg() })

  ws_url <- "wss://api.alpha-strike.space/ws/mails"
  ws <- WebSocket$new(ws_url, autoConnect = FALSE)
  ws$connect()

  ws$onClose(function(event) {
    showNotification("WebSocket disconnected, reconnecting...", type = "warning")
    invalidateLater(2000, session)
    ws$connect()
  })

  ws_messages <- reactiveVal(character(0))

  ws$onMessage(function(event) {
    msg <- event$data
    # Store for debugging
    isolate({
      messages <- ws_messages()
      messages <- c(msg, head(messages, 9))
      ws_messages(messages)
    })
    webhook <- get_webhook()
    if (!is.null(webhook) && nzchar(webhook)) {
      pretty_msg <- build_pretty_msg(msg)
      try({
        httr2::request(webhook) |>
          httr2::req_body_json(list(content = pretty_msg)) |>
          httr2::req_perform()
      }, silent = TRUE)
    }
  })

  observeEvent(input$send_discord_test, {
    webhook <- get_webhook()
    if (!is.null(webhook) && nzchar(webhook)) {
      payload <- list(content = "Thank you for using https://frontier.alpha-strike.space/. It appears your webhook was saved and is accepting messages appropriately.")
      tryCatch({
        resp <- httr2::request(webhook) |>
          httr2::req_body_json(payload) |>
          httr2::req_perform()
        showNotification("Test payload sent to Discord! Check your channel.", type = "message")
      }, error = function(e) {
        showNotification(paste("Failed to send test payload:", e$message), type = "error")
      })
    } else {
      showNotification("No webhook set. Save a webhook first.", type = "error")
    }
  })

  output$ws_messages <- renderText({
    msgs <- rev(ws_messages())
    paste(
      lapply(msgs, function(m) {
        tryCatch(jsonlite::prettify(m), error = function(e) m)
      }),
      collapse = "\n---\n"
    )
  })

  session$onSessionEnded(function() {
    ws$close()
  })
}

shinyApp(ui, server)

