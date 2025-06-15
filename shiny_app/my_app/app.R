# Library calls
library(shiny)
library(websocket)
library(httr2)
library(DBI)
library(RSQLite)
library(jsonlite)
library(lubridate)

# Check sqlite path, otherwise create one.
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
        div(style = "display:inline-block; margin-right:10px;",
            textInput("ws_url", strong("WebSocket URL"),
                      value = "wss://api.alpha-strike.space/ws/mails")
        ),
        div(style = "display:inline-block; margin-right:10px;",
            actionButton("add_webhook", "Add Discord Webhook")
        ),
        div(style = "display:inline-block; margin-right:10px;",
            actionButton("save_webhook", "Save / Update Webhooks")
        ),
        div(style = "display:inline-block; margin-right:10px;",
            actionButton("delete_webhook", "Delete All Webhooks")
        ),
        div(style = "display:inline-block;",
            actionButton("send_discord_test", "Send Test Payload to Discord")
        )
      ),
      br(),
      uiOutput("webhook_inputs"),
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

# Convert Unix timestamp (seconds since 1970-01-01) to UTC time for end-users.
unix_to_utc <- function(unix_timestamp) {
  if (is.null(unix_timestamp) || is.na(unix_timestamp)) return(NA)
  utc_time <- as.POSIXct(as.numeric(unix_timestamp), origin = "1970-01-01", tz = "UTC")
  format(utc_time, "%Y-%m-%d %H:%M:%S UTC")
}

# Build the messages for proper output. This is for discord human readable formatting.
build_pretty_msg <- function(msg) {
  tryCatch({
    obj <- jsonlite::fromJSON(msg, simplifyDataFrame = TRUE)

    # If the message has a 'message' field, just return it.
    if (!is.null(obj$message)) {
      return(obj$message)
    }

    # Helper for single loss event
    format_loss <- function(x) {
      time_str <- if (!is.null(x$time_stamp)) unix_to_utc(x$time_stamp) else "Unknown time"
      mail_link <- if (!is.null(x$id)) sprintf("<https://frontier.alpha-strike.space/pages/killmail.html?mail_id=%s>", x$id) else ""
      sprintf(
        "```🚨 [Incident] %s lost a %s in %s to %s!\nTime: %s ```\n%s",
        x$victim_name, x$loss_type, x$solar_system_name, x$killer_name, time_str, mail_link
      )
    }

    # If it's a single object with the expected fields
    if (is.list(obj) && !is.null(obj$victim_name)) {
      return(format_loss(obj))
    }

    # If it's a list of such objects
    if (is.list(obj) && length(obj) > 0 && !is.null(obj[[1]]$victim_name)) {
      return(paste(
        sapply(obj, format_loss),
        collapse = "\n\n"
      ))
    }

    # Fallback: show first 1900 chars if unknown structure
    substr(msg, 1, 1900)

  }, error = function(e) substr(msg, 1, 1900))
}

server <- function(input, output, session) {
  #print(is.function(build_pretty_msg))
  status_msg <- reactiveVal("No webhooks set.")

  # For dynamic UI
  rv <- reactiveValues(webhooks = list(""))

  # SQLite functions
  get_webhooks <- function() {
    con <- dbConnect(RSQLite::SQLite(), db_path)
    res <- dbGetQuery(con, "SELECT url FROM webhook WHERE id = 1")
    dbDisconnect(con)
    if (nrow(res) == 1) res$url else NULL
  }
  set_webhooks <- function(webhooks) {
    con <- dbConnect(RSQLite::SQLite(), db_path)
    if (length(webhooks) == 0 || (length(webhooks) == 1 && webhooks == "")) {
      dbExecute(con, "DELETE FROM webhook WHERE id = 1")
    } else if (is.null(get_webhooks())) {
      dbExecute(con, "INSERT INTO webhook (id, url) VALUES (1, ?)", params = list(paste(webhooks, collapse = ",")))
    } else {
      dbExecute(con, "UPDATE webhook SET url = ? WHERE id = 1", params = list(paste(webhooks, collapse = ",")))
    }
    dbDisconnect(con)
  }
  delete_webhooks <- function() {
    con <- dbConnect(RSQLite::SQLite(), db_path)
    dbExecute(con, "DELETE FROM webhook WHERE id = 1")
    dbDisconnect(con)
  }

  # Add new input box
  observeEvent(input$add_webhook, {
    rv$webhooks <- c(rv$webhooks, "")
  })

  # Render input boxes
  output$webhook_inputs <- renderUI({
    tagList(
      lapply(seq_along(rv$webhooks), function(i) {
        fluidRow(
          column(10,
                 textInput(paste0("webhook_", i), paste("Discord Webhook URL", i),
                           value = rv$webhooks[[i]], width = "100%")),
          column(2,
                 if (length(rv$webhooks) > 1) {
                   actionButton(paste0("remove_webhook_", i), "Remove", class = "btn-danger", style = "margin-top: 25px;")
                 })
        )
      })
    )
  })

  # Remove a webhook box
  observe({
    lapply(seq_along(rv$webhooks), function(i) {
      observeEvent(input[[paste0("remove_webhook_", i)]], {
        if (length(rv$webhooks) > 1) {
          rv$webhooks <- rv$webhooks[-i]
        }
      }, ignoreInit = TRUE)
    })
  })

  # Save/update logic
  observeEvent(input$save_webhook, {
    ids <- seq_along(rv$webhooks)
    urls <- sapply(ids, function(i) input[[paste0("webhook_", i)]])
    urls <- trimws(urls)
    urls <- urls[urls != ""]
    valid <- all(grepl("^https://discord.com/api/webhooks/", urls))
    if (length(urls) > 0 && valid) {
      set_webhooks(urls)
      status_msg("Webhooks saved or updated!")
      rv$webhooks <- as.list(urls)
    } else {
      status_msg("Invalid Discord webhook URLs.")
    }
  })

  # Delete all webhooks
  observeEvent(input$delete_webhook, {
    delete_webhooks()
    rv$webhooks <- list("")
    status_msg("Webhooks deleted.")
  })

  # On load: populate boxes from DB
  observe({
    current <- get_webhooks()
    if (!is.null(current)) {
      urls <- unlist(strsplit(current, ","))
      urls <- trimws(urls)
      rv$webhooks <- as.list(urls)
      isolate({
        if (status_msg() %in% c("No webhooks set.")) {
          status_msg(paste("Current webhooks loaded."))
        }
      })
    } else {
      rv$webhooks <- list("")
      isolate({
        if (status_msg() %in% c("Webhooks saved or updated!", "Webhooks deleted.", "Invalid Discord webhook URLs.")) {
          # Do not overwrite the result message
        } else {
          status_msg("No webhooks set.")
        }
      })
    }
  })

  output$webhook_status <- renderText({ status_msg() })

  # Dynamic WebSocket connection
  ws_obj <- reactiveVal(NULL)
  ws_messages <- reactiveVal(character(0))

  observe({
    ws_url <- input$ws_url
    if (!is.null(ws_url) && nzchar(ws_url)) {
      ws <- WebSocket$new(ws_url, autoConnect = FALSE)
      ws$connect()
      ws_obj(ws)
      ws$onClose(function(event) {
        showNotification("WebSocket disconnected, reconnecting...", type = "warning")
        invalidateLater(2000, session)
        ws$connect()
      })
      ws$onMessage(function(event) {
        msg <- event$data
        isolate({
          messages <- ws_messages()
          messages <- c(msg, head(messages, 9))
          ws_messages(messages)
        })
        current <- get_webhooks()
        if (!is.null(current) && nzchar(current)) {
          urls <- unlist(strsplit(current, ","))
          urls <- trimws(urls)
          pretty_msg <- build_pretty_msg(msg)
          for (webhook in urls) {
            try({
              httr2::request(webhook) |>
                httr2::req_body_json(list(content = pretty_msg)) |>
                httr2::req_perform()
            }, silent = TRUE)
          }
        }
      })
      session$onSessionEnded(function() {
        ws$close()
      })
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

  # Test message to all webhooks
  observeEvent(input$send_discord_test, {
    current <- get_webhooks()
    if (!is.null(current) && nzchar(current)) {
      urls <- unlist(strsplit(current, ","))
      urls <- trimws(urls)
      payload <- list(content = "Thank you for using https://frontier.alpha-strike.space/. It appears your webhook was saved and is accepting messages appropriately.")
      for (webhook in urls) {
        tryCatch({
          resp <- httr2::request(webhook) |>
            httr2::req_body_json(payload) |>
            httr2::req_perform()
          showNotification(sprintf("Test payload sent to Discord webhook: %s", webhook), type = "message")
        }, error = function(e) {
          showNotification(paste("Failed to send test payload:", e$message), type = "error")
        })
      }
    } else {
      showNotification("No webhooks set. Save webhooks first.", type = "error")
    }
  })
}

shinyApp(ui, server)

