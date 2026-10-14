FROM python:3.12-slim

WORKDIR /app

# Abhaengigkeiten zuerst: aendert sich nur app.py, bleibt diese Schicht im Cache.
RUN pip install --no-cache-dir redis==5.0.8

COPY app.py .

EXPOSE 5000

CMD ["python", "app.py"]
