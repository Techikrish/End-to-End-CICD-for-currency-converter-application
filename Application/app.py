from flask import Flask, render_template, request
import requests

app = Flask(__name__)

API_URL = "https://api.exchangerate-api.com/v4/latest/"

@app.route("/", methods=["GET", "POST"])
def index():
    if request.method == "POST":
        from_currency = request.form.get("from_currency").upper()
        to_currency = request.form.get("to_currency").upper()
        amount = float(request.form.get("amount"))

        response = requests.get(API_URL + from_currency)
        data = response.json()

        if response.status_code != 200:
            return render_template("index.html", error="Invalid currency code.")

        exchange_rate = data["rates"].get(to_currency)
        if not exchange_rate:
            return render_template("index.html", error="Invalid currency code.")

        converted_amount = amount * exchange_rate
        return render_template("index.html", converted_amount=converted_amount, from_currency=from_currency, to_currency=to_currency, amount=amount)

    return render_template("index.html")

if __name__ == "__main__":
    app.run(debug=True)
