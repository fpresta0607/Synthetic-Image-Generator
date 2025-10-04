FROM python:3.11-slim
WORKDIR /app
RUN pip install --no-cache-dir flask
ENV PORT=3000
EXPOSE 3000
COPY app.py .
CMD ["python","app.py"]
