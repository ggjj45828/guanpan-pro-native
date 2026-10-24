FROM python:3.12-slim
WORKDIR /app
# slim 镜像没有 tzdata：没有它 ZoneInfo("Asia/Shanghai") 在运行时直接抛错，
# 行情/分时/日K 全部 502 —— 表现就是「连得上但拿不到数据」。
RUN pip install --no-cache-dir tzdata
# 代码仍然打进镜像：这是**兜底基线**。宿主机挂载的代码由 start.sh 在启动时覆盖进来，
# 所以即使挂载源写错（NAS 上 ./server 解析不到），容器也能正常起来，不会整个 /app 变空。
# 只打包当前研究服务的 Python 模块；已下线的网页与模拟模块不再进入镜像。
COPY *.py ./
COPY VERSION ./
COPY start.sh /app/start.sh
# 构建期做一次导入自检，漏文件会在 build 阶段就失败，而不是等你部署完看日志。
RUN python -c "import app; print('imports ok')"
# /app 要对运行用户可写：start.sh 需要把宿主机代码拷进来。
RUN useradd --uid 10001 --create-home guanpan \
    && mkdir -p /data /opt/guanpan-src \
    && chmod +x /app/start.sh \
    && chown -R guanpan:guanpan /app /data
USER guanpan
EXPOSE 8789
ENTRYPOINT ["/app/start.sh"]
